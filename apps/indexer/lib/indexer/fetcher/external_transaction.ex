defmodule Indexer.Fetcher.ExternalTransaction do
  @moduledoc """
  Fetches and indexes `t:Explorer.Chain.ExternalTransaction.t/0`.

  See `async_fetch/1` for details on configuring limits.
  """

  use Indexer.Fetcher, restart: :permanent
  use Spandex.Decorators

  require Logger

  import Indexer.Block.Fetcher, only: [async_import_coin_balances: 2]

  alias Explorer.Chain
  alias Explorer.Chain.Block
  alias Explorer.Chain.Cache.{Accounts, Blocks}
  alias Explorer.Chain.Import.Runner.Blocks, as: BlocksRunner
  alias Indexer.{BufferedTask, Tracer}
  alias Indexer.Fetcher.ExternalTransaction.Supervisor, as: ExternalTransactionSupervisor
  alias Indexer.Transform.Addresses

  @behaviour BufferedTask

  @default_max_batch_size 10
  @default_max_concurrency 4

  @doc """
  Asynchronously fetches external transactions.

  ## Limiting Upstream Load

  External transactions are an expensive upstream operation. The number of
  results to fetch is configured by `@max_batch_size` and represents the number
  of transaction hashes to request external transactions in a single JSONRPC
  request. Defaults to `#{@default_max_batch_size}`.

  The `@max_concurrency` attribute configures the  number of concurrent requests
  of `@max_batch_size` to allow against the JSONRPC. Defaults to `#{@default_max_concurrency}`.

  *Note*: The external transactions for individual transactions cannot be paginated,
  so the total number of external transactions that could be produced is unknown.
  """
  @spec async_fetch([Block.block_number()]) :: :ok
  def async_fetch(block_numbers, timeout \\ 5000) when is_list(block_numbers) do
    if ExternalTransactionSupervisor.disabled?() do
      :ok
    else
      BufferedTask.buffer(__MODULE__, block_numbers, timeout)
    end
  end

  @doc false
  def child_spec([init_options, gen_server_options]) do
    {state, mergeable_init_options} = Keyword.pop(init_options, :json_rpc_named_arguments)

    unless state do
      raise ArgumentError,
            ":json_rpc_named_arguments must be provided to `#{__MODULE__}.child_spec " <>
              "to allow for json_rpc calls when running."
    end

    merged_init_opts =
      defaults()
      |> Keyword.merge(mergeable_init_options)
      |> Keyword.put(:state, state)

    Supervisor.child_spec({BufferedTask, [{__MODULE__, merged_init_opts}, gen_server_options]}, id: __MODULE__)
  end

  @impl BufferedTask
  def init(initial, reducer, _json_rpc_named_arguments) do
    {:ok, final} =
      Chain.stream_blocks_with_unfetched_external_transactions(initial, fn block_number, acc ->
        reducer.(block_number, acc)
      end)

    final
  end

  defp params(%{block_number: block_number, hash: hash, index: index}) when is_integer(block_number) do
    %{block_number: block_number, hash_data: to_string(hash), transaction_index: index}
  end

  @impl BufferedTask
  @decorate trace(
              name: "fetch",
              resource: "Indexer.Fetcher.ExternalTransaction.run/2",
              service: :indexer,
              tracer: Tracer
            )
  def run(block_numbers, json_rpc_named_arguments) do
    unique_numbers = Enum.uniq(block_numbers)
    filtered_unique_numbers = EthereumJSONRPC.block_numbers_in_range(unique_numbers)

    filtered_unique_numbers_count = Enum.count(filtered_unique_numbers)
    Logger.metadata(count: filtered_unique_numbers_count)

    Logger.debug("fetching external transactions for blocks")

    json_rpc_named_arguments
    |> Keyword.fetch!(:variant)
    |> case do
      EthereumJSONRPC.Nethermind ->
        EthereumJSONRPC.fetch_block_external_transactions(filtered_unique_numbers, json_rpc_named_arguments)

      EthereumJSONRPC.Erigon ->
        EthereumJSONRPC.fetch_block_external_transactions(filtered_unique_numbers, json_rpc_named_arguments)

      EthereumJSONRPC.Besu ->
        EthereumJSONRPC.fetch_block_external_transactions(filtered_unique_numbers, json_rpc_named_arguments)

      _ ->
        try do
          fetch_block_external_transactions_by_transactions(filtered_unique_numbers, json_rpc_named_arguments)
        rescue
          error ->
            {:error, error}
        end
    end
    |> case do
      {:ok, external_transactions_params} ->
        safe_import_external_transaction(external_transactions_params, filtered_unique_numbers)

      {:error, reason} ->
        Logger.error(fn -> ["failed to fetch external transactions for blocks: ", inspect(reason)] end,
          error_count: filtered_unique_numbers_count
        )

        # re-queue the de-duped entries
        {:retry, filtered_unique_numbers}

      :ignore ->
        :ok
    end
  end

  def import_first_trace(external_transactions_params) do
    imports =
      Chain.import(%{
        external_transactions: %{params: external_transactions_params, with: :blockless_changeset},
        timeout: :infinity
      })

    case imports do
      {:error, step, reason, _changes_so_far} ->
        Logger.error(
          fn ->
            [
              "failed to import first trace for tx: ",
              inspect(reason)
            ]
          end,
          step: step
        )
    end
  end

  defp fetch_block_external_transactions_by_transactions(unique_numbers, json_rpc_named_arguments) do
    Enum.reduce(unique_numbers, {:ok, []}, fn
      block_number, {:ok, acc_list} ->
        block_number
        |> Chain.get_transactions_of_block_number()
        |> Enum.map(&params(&1))
        |> case do
          [] ->
            {:ok, []}

          transactions ->
            try do
              EthereumJSONRPC.fetch_external_transactions(transactions, json_rpc_named_arguments)
            catch
              :exit, error ->
                {:error, error}
            end
        end
        |> case do
          {:ok, external_transactions} -> {:ok, external_transactions ++ acc_list}
          error_or_ignore -> error_or_ignore
        end

      _, error_or_ignore ->
        error_or_ignore
    end)
  end

  defp safe_import_external_transaction(external_transactions_params, block_numbers) do
    import_external_transaction(external_transactions_params, block_numbers)
  rescue
    Postgrex.Error ->
      handle_foreign_key_violation(external_transactions_params, block_numbers)
      {:retry, block_numbers}
  end

  defp import_external_transaction(external_transactions_params, unique_numbers) do
    external_transactions_params_without_failed_creations = remove_failed_creations(external_transactions_params)

    addresses_params =
      Addresses.extract_addresses(%{
        external_transactions: external_transactions_params_without_failed_creations
      })

    address_hash_to_block_number =
      Enum.into(addresses_params, %{}, fn %{fetched_coin_balance_block_number: block_number, hash: hash} ->
        {hash, block_number}
      end)

    empty_block_numbers =
      unique_numbers
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(external_transactions_params_without_failed_creations, & &1.block_number))
      |> Enum.map(&%{block_number: &1})

    external_transactions_and_empty_block_numbers =
      external_transactions_params_without_failed_creations ++ empty_block_numbers

    imports =
      Chain.import(%{
        addresses: %{params: addresses_params},
        external_transactions: %{params: external_transactions_and_empty_block_numbers, with: :blockless_changeset},
        timeout: :infinity
      })

    case imports do
      {:ok, imported} ->
        Accounts.drop(imported[:addreses])
        Blocks.drop_nonconsensus(imported[:remove_consensus_of_missing_transactions_blocks])

        async_import_coin_balances(imported, %{
          address_hash_to_fetched_balance_block_number: address_hash_to_block_number
        })

      {:error, step, reason, _changes_so_far} ->
        Logger.error(
          fn ->
            [
              "failed to import external transactions for blocks: ",
              inspect(reason)
            ]
          end,
          step: step,
          error_count: Enum.count(unique_numbers)
        )

        # re-queue the de-duped entries
        {:retry, unique_numbers}
    end
  end

  defp remove_failed_creations(external_transactions_params) do
    external_transactions_params
    |> Enum.map(fn external_transaction_param ->
      transaction_index = external_transaction_param[:transaction_index]
      block_number = external_transaction_param[:block_number]

      failed_parent =
        external_transactions_params
        |> Enum.filter(fn external_transactions_param ->
          external_transactions_param[:block_number] == block_number &&
            external_transactions_param[:transaction_index] == transaction_index &&
            external_transactions_param[:trace_address] == [] && !is_nil(external_transactions_param[:error])
        end)
        |> Enum.at(0)

      if failed_parent do
        external_transaction_param
        |> Map.delete(:created_contract_address_hash)
        |> Map.delete(:created_contract_code)
        |> Map.delete(:gas_used)
        |> Map.delete(:output)
        |> Map.put(:error, failed_parent[:error])
      else
        external_transaction_param
      end
    end)
  end

  defp handle_foreign_key_violation(external_transactions_params, block_numbers) do
    BlocksRunner.invalidate_consensus_blocks(block_numbers)

    transaction_hashes =
      external_transactions_params
      |> Enum.map(&to_string(&1.transaction_hash))
      |> Enum.uniq()

    Logger.error(fn ->
      [
        "foreign_key_violation on external transactions import, foreign transactions hashes: ",
        Enum.join(transaction_hashes, ", ")
      ]
    end)
  end

  defp defaults do
    [
      flush_interval: :timer.seconds(3),
      max_concurrency: Application.get_env(:indexer, __MODULE__)[:concurrency] || @default_max_concurrency,
      max_batch_size: Application.get_env(:indexer, __MODULE__)[:batch_size] || @default_max_batch_size,
      poll: true,
      task_supervisor: Indexer.Fetcher.ExternalTransaction.TaskSupervisor,
      metadata: [fetcher: :external_transaction]
    ]
  end
end
