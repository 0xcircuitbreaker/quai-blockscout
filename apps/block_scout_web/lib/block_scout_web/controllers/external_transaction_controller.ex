defmodule BlockScoutWeb.ExternalTransactionController do
  use BlockScoutWeb, :controller
  import BlockScoutWeb.Account.AuthController, only: [current_user: 1]

  import BlockScoutWeb.Chain,
    only: [
      fetch_page_number: 1,
      paging_options: 1,
      next_page_params: 3,
      update_page_parameters: 3,
      split_list_by_page: 1
    ]

  import BlockScoutWeb.Models.GetAddressTags, only: [get_address_tags: 2]
  import BlockScoutWeb.Models.GetTransactionTags, only: [get_transaction_with_addresses_tags: 2]

  alias BlockScoutWeb.{
    AccessHelpers,
    Controller,
    TransactionInternalTransactionController,
    TransactionTokenTransferController,
    ExternalTransactionView
  }

  alias Explorer.{Chain, Market}
  alias Explorer.Chain.Cache.ExternalTransaction, as: ExternalTransactionCache
  alias Explorer.ExchangeRates.Token
  alias Phoenix.View

  @necessity_by_association %{
    :block => :optional,
    [created_contract_address: :names] => :optional,
    [from_address: :names] => :optional,
    [to_address: :names] => :optional,
    [to_address: :smart_contract] => :optional,
    :token_transfers => :optional
  }

  {:ok, burn_address_hash} = Chain.string_to_address_hash("0x0000000000000000000000000000000000000000")
  @burn_address_hash burn_address_hash

  @default_options [
    necessity_by_association: %{
      :block => :required,
      [created_contract_address: :names] => :optional,
      [from_address: :names] => :optional,
      [to_address: :names] => :optional,
      [created_contract_address: :smart_contract] => :optional,
      [from_address: :smart_contract] => :optional,
      [to_address: :smart_contract] => :optional
    }
  ]

  def index(conn, %{"type" => "JSON"} = params) do
    options =
      @default_options
      |> Keyword.merge(paging_options(params))

    full_options =
      options
      |> Keyword.put(
        :paging_options,
        params
        |> fetch_page_number()
        |> update_page_parameters(Chain.default_page_size(), Keyword.get(options, :paging_options))
      )

    %{total_transactions_count: transactions_count, transactions: transactions_plus_one} =
      Chain.recent_collated_external_transactions_for_rap(full_options)

    {transactions, next_page} =
      if fetch_page_number(params) == 1 do
        split_list_by_page(transactions_plus_one)
      else
        {transactions_plus_one, nil}
      end

    next_page_params =
      if fetch_page_number(params) == 1 do
        page_size = Chain.default_page_size()

        pages_limit = transactions_count |> Kernel./(page_size) |> Float.ceil() |> trunc()

        case next_page_params(next_page, transactions, params) do
          nil ->
            nil

          next_page_params ->
            next_page_params
            |> Map.delete("type")
            |> Map.delete("items_count")
            |> Map.put("pages_limit", pages_limit)
            |> Map.put("page_size", page_size)
            |> Map.put("page_number", 1)
        end
      else
        Map.delete(params, "type")
      end

    json(
      conn,
      %{
        items:
          Enum.map(transactions, fn transaction ->
            View.render_to_string(
              ExternalTransactionView,
              "_tile.html",
              transaction: transaction,
              burn_address_hash: @burn_address_hash,
              conn: conn
            )
          end),
        next_page_params: next_page_params
      }
    )
  end

  def index(conn, _params) do
    transaction_estimated_count = ExternalTransactionCache.estimated_count()

    render(
      conn,
      "index.html",
      current_path: Controller.current_full_path(conn),
      transaction_estimated_count: transaction_estimated_count
    )
  end

  defp is_nonempty_array(%{"items" => items} = value) when is_map(value) and is_list(items) and length(items) > 0, do: true
  defp is_nonempty_array(_), do: false


  def show(conn, %{"id" => transaction_hash_string, "type" => "JSON"}) do
    IO.puts("we are here in JSON")
    case Chain.string_to_transaction_hash(transaction_hash_string) do
      {:ok, transaction_hash} ->
        if Chain.transaction_has_token_transfers?(transaction_hash) do
          TransactionTokenTransferController.index(conn, %{
            "transaction_id" => transaction_hash_string,
            "type" => "JSON"
          })
        else
          TransactionInternalTransactionController.index(conn, %{
            "transaction_id" => transaction_hash_string,
            "type" => "JSON"
          })
        end

      :error ->
        set_not_found_view(conn, transaction_hash_string)
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, transaction_hash} <- Chain.string_to_transaction_hash(id),
         :ok <- Chain.check_external_transaction_exists(transaction_hash) do
      if false do
        with {:ok, transaction} <-
               Chain.hash_to_external_transaction(
                 transaction_hash,
                 necessity_by_association: @necessity_by_association
               ),
             {:ok, false} <- AccessHelpers.restricted_access?(to_string(transaction.from_address_hash), params),
             {:ok, false} <- AccessHelpers.restricted_access?(to_string(transaction.to_address_hash), params) do
          render(
            conn,
            "show_token_transfers.html",
            exchange_rate: Market.get_exchange_rate(Explorer.coin()) || Token.null(),
            block_height: Chain.block_height(),
            current_path: Controller.current_full_path(conn),
            current_user: current_user(conn),
            show_token_transfers: true,
            transaction: transaction,
            from_tags: get_address_tags(transaction.from_address_hash, current_user(conn)),
            to_tags: get_address_tags(transaction.to_address_hash, current_user(conn)),
            tx_tags:
              get_transaction_with_addresses_tags(
                transaction,
                current_user(conn)
              )
          )
        else
          :not_found ->
            set_not_found_view(conn, id)

          :error ->
            unprocessable_entity(conn)

          {:error, :not_found} ->
            set_not_found_view(conn, id)

          {:restricted_access, _} ->
            set_not_found_view(conn, id)
        end
      else
        with {:ok, transaction} <-
               Chain.hash_to_external_transaction(
                 transaction_hash,
                 necessity_by_association: @necessity_by_association
               ),
             {:ok, false} <- AccessHelpers.restricted_access?(to_string(transaction.from_address_hash), params),
             {:ok, false} <- AccessHelpers.restricted_access?(to_string(transaction.to_address_hash), params) do
          render(
            conn,
            "show_internal_transactions.html",
            exchange_rate: Market.get_exchange_rate(Explorer.coin()) || Token.null(),
            current_path: Controller.current_full_path(conn),
            current_user: current_user(conn),
            block_height: Chain.block_height(),
            show_token_transfers: Chain.transaction_has_token_transfers?(transaction_hash),
            transaction: transaction,
            from_tags: get_address_tags(transaction.from_address_hash, current_user(conn)),
            to_tags: get_address_tags(transaction.to_address_hash, current_user(conn)),
            tx_tags:
              get_transaction_with_addresses_tags(
                transaction,
                current_user(conn)
              )
          )
        else
          :not_found ->
            set_not_found_view(conn, id)

          :error ->
            unprocessable_entity(conn)

          {:error, :not_found} ->
            set_not_found_view(conn, id)

          {:restricted_access, _} ->
            set_not_found_view(conn, id)
        end
      end
    else
      :error ->
        unprocessable_entity(conn)

      :not_found ->
        {:ok, response} = HTTPoison.get("#{System.get_env("RUST_MULTICHAIN_SEARCH_URL")}/api/v1/search?q=" <> id, [], params: [])
        chain_with_tx = response.body |> Poison.decode() |> elem(1) |> Map.values() |> Enum.find(
                                                                         fn x ->
                                                                           x |> Map.get("content") |> Poison.decode() |> elem(1) |> is_nonempty_array()
                                                                         end)
        if chain_with_tx != nil do
          conn |> redirect(external: chain_with_tx |> Map.get("uri") |> String.replace("/api/v1", ""))
        end
        set_not_found_view(conn, id)
    end
  end

  def set_not_found_view(conn, transaction_hash_string) do
    conn
    |> put_status(404)
    |> put_view(ExternalTransactionView)
    |> render("not_found.html", transaction_hash: transaction_hash_string)
  end
end
