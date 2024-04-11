defmodule Explorer.Chain.Optimism.Withdrawal do
  @moduledoc "Models Optimism withdrawal."

  use Explorer.Schema

  import Explorer.Chain, only: [select_repo: 1]

  alias Explorer.Application.Constants
  alias Explorer.Chain.{Block, Hash, Transaction}
  alias Explorer.Chain.Cache.OptimismFinalizationPeriod
  alias Explorer.Chain.Optimism.{DisputeGame, OutputRoot, WithdrawalEvent}
  alias Explorer.{Helper, PagingOptions, Repo}

  @default_paging_options %PagingOptions{page_size: 50}

  @game_status_defender_wins 2

  @withdrawal_status_waiting_for_state_root "Waiting for state root"
  @withdrawal_status_ready_to_prove "Ready to prove"
  @withdrawal_status_waiting_to_resolve "Waiting a game to resolve"
  @withdrawal_status_in_challenge "In challenge period"
  @withdrawal_status_ready_for_relay "Ready for relay"
  @withdrawal_status_relayed "Relayed"

  @required_attrs ~w(msg_nonce hash l2_transaction_hash l2_block_number)a

  @type t :: %__MODULE__{
          msg_nonce: Decimal.t(),
          hash: Hash.t(),
          l2_transaction_hash: Hash.t(),
          l2_block_number: non_neg_integer()
        }

  @primary_key false
  schema "op_withdrawals" do
    field(:msg_nonce, :decimal, primary_key: true)
    field(:hash, Hash.Full)
    field(:l2_transaction_hash, Hash.Full)
    field(:l2_block_number, :integer)

    timestamps()
  end

  def changeset(%__MODULE__{} = withdrawals, attrs \\ %{}) do
    withdrawals
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
  end

  @doc """
  Lists `t:Explorer.Chain.Optimism.Withdrawal.t/0`'s' in descending order based on message nonce.

  """
  @spec list :: [__MODULE__.t()]
  def list(options \\ []) do
    paging_options = Keyword.get(options, :paging_options, @default_paging_options)

    base_query =
      from(w in __MODULE__,
        order_by: [desc: w.msg_nonce],
        left_join: l2_tx in Transaction,
        on: w.l2_transaction_hash == l2_tx.hash,
        left_join: l2_block in Block,
        on: w.l2_block_number == l2_block.number,
        left_join: we in WithdrawalEvent,
        on: we.withdrawal_hash == w.hash and we.l1_event_type == :WithdrawalFinalized,
        select: %{
          msg_nonce: w.msg_nonce,
          hash: w.hash,
          l2_block_number: w.l2_block_number,
          l2_timestamp: l2_block.timestamp,
          l2_transaction_hash: w.l2_transaction_hash,
          l1_transaction_hash: we.l1_transaction_hash,
          from: l2_tx.from_address_hash
        }
      )

    base_query
    |> page_optimism_withdrawals(paging_options)
    |> limit(^paging_options.page_size)
    |> select_repo(options).all()
  end

  defp page_optimism_withdrawals(query, %PagingOptions{key: nil}), do: query

  defp page_optimism_withdrawals(query, %PagingOptions{key: {nonce}}) do
    from(w in query, where: w.msg_nonce < ^nonce)
  end

  @doc """
    Gets withdrawal statuses for Optimism Withdrawal transaction.
    For each withdrawal associated with this transaction,
    returns the status and the corresponding L1 transaction hash if the status is `Relayed`.
  """
  @spec transaction_statuses(Hash.t()) :: [{non_neg_integer(), String.t(), Hash.t() | nil}]
  def transaction_statuses(l2_transaction_hash) do
    query =
      from(w in __MODULE__,
        where: w.l2_transaction_hash == ^l2_transaction_hash,
        left_join: l2_block in Block,
        on: w.l2_block_number == l2_block.number and l2_block.consensus == true,
        left_join: we in WithdrawalEvent,
        on: we.withdrawal_hash == w.hash and we.l1_event_type == :WithdrawalFinalized,
        select: %{
          hash: w.hash,
          l2_block_number: w.l2_block_number,
          l1_transaction_hash: we.l1_transaction_hash,
          msg_nonce: w.msg_nonce
        }
      )

    query
    |> Repo.replica().all()
    |> Enum.map(fn w ->
      msg_nonce =
        Bitwise.band(
          Decimal.to_integer(w.msg_nonce),
          0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
        )

      {status, _} = status(w)
      {msg_nonce, status, w.l1_transaction_hash}
    end)
  end

  @doc """
    Gets Optimism Withdrawal status and remaining time to unlock (when the status is `In challenge period`).
  """
  @spec status(map()) :: {String.t(), DateTime.t() | nil}
  def status(w) when is_nil(w.l1_transaction_hash) do
    withdrawal_event =
      Repo.replica().one(
        from(
          we in WithdrawalEvent,
          select: {we.l1_timestamp, we.game_index},
          where: we.withdrawal_hash == ^w.hash and we.l1_event_type == :WithdrawalProven
        )
      )

    if is_nil(withdrawal_event) do
      last_root_l2_block_number =
        Repo.replica().one(
          from(root in OutputRoot,
            select: root.l2_block_number,
            order_by: [desc: root.l2_output_index],
            limit: 1
          )
        ) || 0

      if w.l2_block_number <= last_root_l2_block_number or appropriate_games_found(w.l2_block_number) do
        {@withdrawal_status_ready_to_prove, nil}
      else
        {@withdrawal_status_waiting_for_state_root, nil}
      end
    else
      {l1_timestamp, game_index} = withdrawal_event

      game =
        if not is_nil(game_index) do
          Repo.replica().one(
            from(
              g in DisputeGame,
              select: %{created_at: g.created_at, resolved_at: g.resolved_at, status: g.status},
              where: g.index == ^game_index
            )
          )
        end

      if is_nil(game) or DateTime.compare(l1_timestamp, game.created_at) == :lt do
        # the old status determining approach
        pre_fault_proofs_status(l1_timestamp)
      else
        # the new status determining approach
        post_fault_proofs_status(l1_timestamp, game)
      end
    end
  end

  def status(_w) do
    {@withdrawal_status_relayed, nil}
  end

  defp appropriate_games_found(withdrawal_l2_block_number) do
    case Helper.parse_integer(Constants.get_constant_value("optimism_respected_game_type")) do
      nil ->
        false

      game_type ->
        query =
          from(g in DisputeGame,
            where: g.game_type == ^game_type,
            order_by: [desc: g.index],
            limit: 100
          )

        query
        |> Repo.all(timeout: :infinity)
        |> Enum.any?(fn game ->
          [l2_block_number] = Helper.decode_data(game.extra_data, [{:uint, 256}])
          withdrawal_l2_block_number <= l2_block_number
        end)
    end
  end

  defp pre_fault_proofs_status(l1_timestamp) do
    challenge_period =
      case OptimismFinalizationPeriod.get_period() do
        nil -> 604_800
        period -> period
      end

    if DateTime.compare(l1_timestamp, DateTime.add(DateTime.utc_now(), -challenge_period)) == :lt do
      {@withdrawal_status_ready_for_relay, nil}
    else
      {@withdrawal_status_in_challenge, DateTime.add(l1_timestamp, challenge_period)}
    end
  end

  defp post_fault_proofs_status(l1_timestamp, game) do
    if game.status != @game_status_defender_wins do
      # the game status is not DEFENDER_WINS
      {@withdrawal_status_waiting_to_resolve, nil}
    else
      dispute_game_finality_delay_seconds =
        Helper.parse_integer(Constants.get_constant_value("optimism_dispute_game_finality_delay_seconds"))

      proof_maturity_delay_seconds =
        Helper.parse_integer(Constants.get_constant_value("optimism_proof_maturity_delay_seconds"))

      false = is_nil(dispute_game_finality_delay_seconds)
      false = is_nil(proof_maturity_delay_seconds)

      finality_delayed = DateTime.add(game.resolved_at, dispute_game_finality_delay_seconds)
      proof_delayed = DateTime.add(l1_timestamp, proof_maturity_delay_seconds)

      now = DateTime.utc_now()

      if DateTime.compare(now, finality_delayed) == :lt or DateTime.compare(now, finality_delayed) == :eq or
           DateTime.compare(now, proof_delayed) == :lt or DateTime.compare(now, proof_delayed) == :eq do
        seconds_left1 = max(DateTime.diff(finality_delayed, now), 0)
        seconds_left2 = max(DateTime.diff(proof_delayed, now), 0)
        seconds_left = max(seconds_left1, seconds_left2)

        {@withdrawal_status_in_challenge, DateTime.add(now, seconds_left)}
      else
        {@withdrawal_status_ready_for_relay, nil}
      end
    end
  end
end
