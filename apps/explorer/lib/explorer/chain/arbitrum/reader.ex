defmodule Explorer.Chain.Arbitrum.Reader do
  @moduledoc """
  Contains read functions for Arbitrum modules.
  """

  import Ecto.Query, only: [from: 2, subquery: 1]

  alias Explorer.Chain.Arbitrum.{BatchBlock, L1Batch, L1Execution, LifecycleTransaction, Message}

  alias Explorer.{Chain, Repo}

  alias Explorer.Chain.Block, as: FullBlock
  alias Explorer.Chain.{Hash, Transaction}

  @doc """
    Retrieves the number of the latest L1 block where an L1-to-L2 message was discovered.

    ## Returns
    - The number of L1 block, or `nil` if no L1-to-L2 messages are found.
  """
  @spec l1_block_of_latest_discovered_message_to_l2() :: FullBlock.block_number() | nil
  def l1_block_of_latest_discovered_message_to_l2 do
    query =
      from(msg in Message,
        select: msg.originating_tx_blocknum,
        where: msg.direction == :to_l2 and not is_nil(msg.originating_tx_blocknum),
        order_by: [desc: msg.message_id],
        limit: 1
      )

    query
    |> Repo.one()
  end

  @doc """
    Retrieves the number of the earliest L1 block where an L1-to-L2 message was discovered.

    ## Returns
    - The number of L1 block, or `nil` if no L1-to-L2 messages are found.
  """
  @spec l1_block_of_earliest_discovered_message_to_l2() :: FullBlock.block_number() | nil
  def l1_block_of_earliest_discovered_message_to_l2 do
    query =
      from(msg in Message,
        select: msg.originating_tx_blocknum,
        where: msg.direction == :to_l2 and not is_nil(msg.originating_tx_blocknum),
        order_by: [asc: msg.message_id],
        limit: 1
      )

    query
    |> Repo.one()
  end

  @doc """
    Retrieves the number of the earliest rollup block where an L2-to-L1 message was discovered.

    ## Returns
    - The number of rollup block, or `nil` if no L2-to-L1 messages are found.
  """
  @spec rollup_block_of_earliest_discovered_message_from_l2() :: FullBlock.block_number() | nil
  def rollup_block_of_earliest_discovered_message_from_l2 do
    query =
      from(msg in Message,
        select: msg.originating_tx_blocknum,
        where: msg.direction == :from_l2 and not is_nil(msg.originating_tx_blocknum),
        order_by: [asc: msg.originating_tx_blocknum],
        limit: 1
      )

    query
    |> Repo.one()
  end

  @doc """
    Retrieves the number of the earliest rollup block where a completed L1-to-L2 message was discovered.

    ## Returns
    - The block number of the rollup block, or `nil` if no completed L1-to-L2 messages are found,
      or if the rollup transaction that emitted the corresponding message has not been indexed yet.
  """
  @spec rollup_block_of_earliest_discovered_message_to_l2() :: FullBlock.block_number() | nil
  def rollup_block_of_earliest_discovered_message_to_l2 do
    completion_tx_subquery =
      from(msg in Message,
        select: msg.completion_tx_hash,
        where: msg.direction == :to_l2 and not is_nil(msg.completion_tx_hash),
        order_by: [asc: msg.message_id],
        limit: 1
      )

    query =
      from(tx in Transaction,
        select: tx.block_number,
        where: tx.hash == subquery(completion_tx_subquery),
        limit: 1
      )

    query
    |> Repo.one()
  end

  @doc """
    Retrieves the number of the latest L1 block where the commitment transaction with a batch was included.

    As per the Arbitrum rollup nature, from the indexer's point of view, a batch does not exist until
    the commitment transaction is submitted to L1. Therefore, the situation where a batch exists but
    there is no commitment transaction is not possible.

    ## Returns
    - The number of the L1 block, or `nil` if no rollup batches are found, or if the association between the batch
      and the commitment transaction has been broken due to database inconsistency.
  """
  @spec l1_block_of_latest_committed_batch() :: FullBlock.block_number() | nil
  def l1_block_of_latest_committed_batch do
    query =
      from(batch in L1Batch,
        order_by: [desc: batch.number],
        limit: 1
      )

    case query
         |> Chain.join_associations(%{:commit_transaction => :required})
         |> Repo.one() do
      nil -> nil
      batch -> batch.commit_transaction.block
    end
  end

  @doc """
    Retrieves the number of the earliest L1 block where the commitment transaction with a batch was included.

    As per the Arbitrum rollup nature, from the indexer's point of view, a batch does not exist until
    the commitment transaction is submitted to L1. Therefore, the situation where a batch exists but
    there is no commitment transaction is not possible.

    ## Returns
    - The number of the L1 block, or `nil` if no rollup batches are found, or if the association between the batch
      and the commitment transaction has been broken due to database inconsistency.
  """
  @spec l1_block_of_earliest_committed_batch() :: FullBlock.block_number() | nil
  def l1_block_of_earliest_committed_batch do
    query =
      from(batch in L1Batch,
        order_by: [asc: batch.number],
        limit: 1
      )

    case query
         |> Chain.join_associations(%{:commit_transaction => :required})
         |> Repo.one() do
      nil -> nil
      batch -> batch.commit_transaction.block
    end
  end

  @doc """
    Retrieves the block number of the highest rollup block that has been included in a batch.

    ## Returns
    - The number of the highest rollup block included in a batch, or `nil` if no rollup batches are found.
  """
  @spec highest_committed_block() :: FullBlock.block_number() | nil
  def highest_committed_block do
    query =
      from(batch in L1Batch,
        select: batch.end_block,
        order_by: [desc: batch.number],
        limit: 1
      )

    query
    |> Repo.one()
  end

  @doc """
    Reads a list of L1 transactions by their hashes from the `arbitrum_lifecycle_l1_transactions` table.

    ## Parameters
    - `l1_tx_hashes`: A list of hashes to retrieve L1 transactions for.

    ## Returns
    - A list of `Explorer.Chain.Arbitrum.LifecycleTransaction` corresponding to the hashes from
      the input list. The output list may be smaller than the input list.
  """
  @spec lifecycle_transactions(maybe_improper_list(Hash, [])) :: [LifecycleTransaction]
  def lifecycle_transactions(l1_tx_hashes) when is_list(l1_tx_hashes) do
    query =
      from(
        lt in LifecycleTransaction,
        select: {lt.hash, lt.id},
        where: lt.hash in ^l1_tx_hashes
      )

    Repo.all(query, timeout: :infinity)
  end

  @doc """
    Reads a list of transactions executing L2-to-L1 messages by their IDs.

    ## Parameters
    - `message_ids`: A list of IDs to retrieve executing transactions for.

    ## Returns
    - A list of `Explorer.Chain.Arbitrum.L1Execution` corresponding to the message IDs from
      the input list. The output list may be smaller than the input list if some IDs do not
      correspond to any existing transactions.
  """
  @spec l1_executions(maybe_improper_list(non_neg_integer(), [])) :: [L1Execution]
  def l1_executions(message_ids) when is_list(message_ids) do
    query =
      from(
        ex in L1Execution,
        where: ex.message_id in ^message_ids
      )

    query
    |> Chain.join_associations(%{
      :execution_transaction => :optional
    })
    |> Repo.all(timeout: :infinity)
  end

  @doc """
    Determines the next index for the L1 transaction available in the `arbitrum_lifecycle_l1_transactions` table.

    ## Returns
    - The next available index. If there are no L1 transactions imported yet, it will return `1`.
  """
  @spec next_id() :: non_neg_integer
  def next_id do
    query =
      from(lt in LifecycleTransaction,
        select: lt.id,
        order_by: [desc: lt.id],
        limit: 1
      )

    last_id =
      query
      |> Repo.one()
      |> Kernel.||(0)

    last_id + 1
  end

  @doc """
    Retrieves unfinalized L1 transactions from the `LifecycleTransaction` table that are
    involved in changing the statuses of rollup blocks or transactions.

    An L1 transaction is considered unfinalized if it has not yet reached a state where
    it is permanently included in the blockchain, meaning it is still susceptible to
    potential reorganization or change. Transactions are evaluated against the `finalized_block`
    parameter to determine their finalized status.

    ## Parameters
    - `finalized_block`: The L1 block number above which transactions are considered finalized.
      Transactions in blocks higher than this number are not included in the results.

    ## Returns
    - A list of `Explorer.Chain.Arbitrum.LifecycleTransaction` representing unfinalized transactions,
      or `[]` if no unfinalized transactions are found.
  """
  @spec lifecycle_unfinalized_transactions(FullBlock.block_number()) :: [LifecycleTransaction]
  def lifecycle_unfinalized_transactions(finalized_block)
      when is_integer(finalized_block) and finalized_block >= 0 do
    query =
      from(
        lt in LifecycleTransaction,
        where: lt.block <= ^finalized_block and lt.status == :unfinalized
      )

    Repo.all(query, timeout: :infinity)
  end

  @doc """
    Gets the rollup block number by the hash of the block. Lookup is performed only
    for blocks explicitly included in a batch, i.e., the batch has been identified by
    the corresponding fetcher. The function may return `nil` as a successful response
    if the batch containing the rollup block has not been indexed yet.

    ## Parameters
    - `block_hash`: The hash of a block included in the batch.

    ## Returns
    - `{:ok, block_number}` where `block_number` is the number of the rollup block corresponding to the given hash.
    - `{:ok, nil}` if there is no batch corresponding to the block with the given hash.
    - `{:error, nil}` if the database inconsistency is identified.
  """
  @spec rollup_block_hash_to_num(binary()) :: {:error, nil} | {:ok, FullBlock.block_number() | nil}
  def rollup_block_hash_to_num(block_hash) when is_binary(block_hash) do
    query =
      from(bl in BatchBlock,
        where: bl.hash == ^block_hash
      )

    case query
         |> Chain.join_associations(%{
           :block => :optional
         })
         |> Repo.one() do
      nil ->
        # Block with such hash is not found
        {:ok, nil}

      rollup_block ->
        case rollup_block.block do
          # `nil` and `%Ecto.Association.NotLoaded{}` indicate DB inconsistency
          nil -> {:error, nil}
          %Ecto.Association.NotLoaded{} -> {:error, nil}
          associated_block -> {:ok, associated_block.number}
        end
    end
  end

  @doc """
    Checks if the numbers from the provided list correspond to the numbers of indexed batches.

    ## Parameters
    - `batches_numbers`: The list of batch numbers.

    ## Returns
    - A list of batch numbers that are indexed and match the provided list, or `[]`
      if none of the batch numbers in the provided list exist in the database. The output list
      may be smaller than the input list.
  """
  @spec batches_exist(maybe_improper_list(non_neg_integer(), [])) :: [non_neg_integer]
  def batches_exist(batches_numbers) when is_list(batches_numbers) do
    query =
      from(
        batch in L1Batch,
        select: batch.number,
        where: batch.number in ^batches_numbers
      )

    query
    |> Repo.all(timeout: :infinity)
  end

  @doc """
    Retrieves the batch in which the rollup block, identified by the given block number, was included.

    ## Parameters
    - `number`: The number of a rollup block.

    ## Returns
    - An instance of `Explorer.Chain.Arbitrum.L1Batch` representing the batch containing
      the specified rollup block number, or `nil` if no corresponding batch is found.
  """
  @spec get_batch_by_rollup_block_num(FullBlock.block_number()) :: L1Batch | nil
  def get_batch_by_rollup_block_num(number)
      when is_integer(number) and number >= 0 do
    query =
      from(batch in L1Batch,
        # end_block has higher number than start_block
        where: batch.end_block >= ^number and batch.start_block <= ^number
      )

    query
    |> Chain.join_associations(%{:commit_transaction => :required})
    |> Repo.one()
  end

  @doc """
    Retrieves the L1 block number where the confirmation transaction of the highest confirmed rollup block was included.

    ## Returns
    - The L1 block number if a confirmed rollup block is found and the confirmation transaction is indexed;
      `nil` if no confirmed rollup blocks are found or if there is a database inconsistency.
  """
  @spec l1_block_of_latest_confirmed_block() :: FullBlock.block_number() | nil
  def l1_block_of_latest_confirmed_block do
    query =
      from(
        rb in BatchBlock,
        inner_join: fb in FullBlock,
        on: rb.hash == fb.hash,
        select: rb,
        where: not is_nil(rb.confirm_id),
        order_by: [desc: fb.number],
        limit: 1
      )

    case query
         |> Chain.join_associations(%{
           :confirm_transaction => :optional
         })
         |> Repo.one() do
      nil ->
        nil

      block ->
        case block.confirm_transaction do
          # `nil` and `%Ecto.Association.NotLoaded{}` indicate DB inconsistency
          nil -> nil
          %Ecto.Association.NotLoaded{} -> nil
          confirm_transaction -> confirm_transaction.block
        end
    end
  end

  @doc """
    Retrieves the number of the highest confirmed rollup block.

    ## Returns
    - The number of the highest confirmed rollup block, or `nil` if no confirmed rollup blocks are found.
  """
  @spec highest_confirmed_block() :: FullBlock.block_number() | nil
  def highest_confirmed_block do
    query =
      from(
        rb in BatchBlock,
        inner_join: fb in FullBlock,
        on: rb.hash == fb.hash,
        select: fb.number,
        where: not is_nil(rb.confirm_id),
        order_by: [desc: fb.number],
        limit: 1
      )

    query
    |> Repo.one()
  end

  @doc """
    Retrieves the number of the latest L1 block where a transaction executing an L2-to-L1 message was discovered.

    ## Returns
    - The number of the latest L1 block with an executing transaction for an L2-to-L1 message, or `nil` if no such transactions are found.
  """
  @spec l1_block_of_latest_execution() :: FullBlock.block_number() | nil
  def l1_block_of_latest_execution do
    query =
      from(
        tx in LifecycleTransaction,
        inner_join: ex in L1Execution,
        on: tx.id == ex.execution_id,
        select: tx.block,
        order_by: [desc: tx.block],
        limit: 1
      )

    query
    |> Repo.one()
  end

  @doc """
    Retrieves the number of the earliest L1 block where a transaction executing an L2-to-L1 message was discovered.

    ## Returns
    - The number of the earliest L1 block with an executing transaction for an L2-to-L1 message, or `nil` if no such transactions are found.
  """
  @spec l1_block_of_earliest_execution() :: FullBlock.block_number() | nil
  def l1_block_of_earliest_execution do
    query =
      from(
        tx in LifecycleTransaction,
        inner_join: ex in L1Execution,
        on: tx.id == ex.execution_id,
        select: tx.block,
        order_by: [asc: tx.block],
        limit: 1
      )

    query
    |> Repo.one()
  end

  @doc """
    Retrieves all unconfirmed rollup blocks within the specified range from `first_block` to `last_block`,
    inclusive, where `first_block` is less than or equal to `last_block`.

    Since the function relies on the block data generated by the block fetcher, the returned list
    may contain fewer blocks than actually exist if some of the blocks have not been indexed by the fetcher yet.

    ## Parameters
    - `first_block`: The rollup block number starting the lookup range.
    - `last_block`:The rollup block number ending the lookup range.

    ## Returns
    - A list of maps containing the batch number, rollup block number and hash for each
      unconfirmed block within the range. Returns `[]` if no unconfirmed blocks are found
      within the range, or if the block fetcher has not indexed them.
  """
  @spec unconfirmed_rollup_blocks(FullBlock.block_number(), FullBlock.block_number()) :: [
          %{batch_number: non_neg_integer, block_num: FullBlock.block_number(), hash: Hash.t()}
        ]
  def unconfirmed_rollup_blocks(first_block, last_block)
      when is_integer(first_block) and first_block >= 0 and
             is_integer(last_block) and first_block <= last_block do
    query =
      from(
        rb in BatchBlock,
        inner_join: fb in FullBlock,
        on: rb.hash == fb.hash,
        select: %{
          batch_number: rb.batch_number,
          hash: rb.hash,
          block_num: fb.number
        },
        where: fb.number >= ^first_block and fb.number <= ^last_block and is_nil(rb.confirm_id),
        order_by: [asc: fb.number]
      )

    Repo.all(query, timeout: :infinity)
  end

  @doc """
    Calculates the number of confirmed rollup blocks in the specified batch.

    ## Parameters
    - `batch_number`: The number of the batch for which the count of confirmed blocks is to be calculated.

    ## Returns
    - The number of confirmed blocks in the batch with the given number.
  """
  @spec count_confirmed_rollup_blocks_in_batch(non_neg_integer()) :: non_neg_integer
  def count_confirmed_rollup_blocks_in_batch(batch_number)
      when is_integer(batch_number) and batch_number >= 0 do
    query =
      from(
        rb in BatchBlock,
        where: rb.batch_number == ^batch_number and not is_nil(rb.confirm_id)
      )

    Repo.aggregate(query, :count, timeout: :infinity)
  end

  @doc """
    Retrieves all L2-to-L1 messages with the specified status that originated in rollup blocks with numbers not higher than `block_number`.

    ## Parameters
    - `status`: The status of the messages to retrieve, such as `:initiated`, `:sent`, `:confirmed`, or `:relayed`.
    - `block_number`: The number of a rollup block that limits the messages lookup.

    ## Returns
    - Instances of `Explorer.Chain.Arbitrum.Message` corresponding to the criteria, or `[]` if no messages
      with the given status are found in the rollup blocks up to the specified number.
  """
  @spec l2_to_l1_messages(:confirmed | :initiated | :relayed | :sent, FullBlock.block_number()) :: [
          Message
        ]
  def l2_to_l1_messages(status, block_number)
      when status in [:initiated, :sent, :confirmed, :relayed] and
             is_integer(block_number) and
             block_number >= 0 do
    query =
      from(msg in Message,
        where: msg.direction == :from_l2 and msg.originating_tx_blocknum <= ^block_number and msg.status == ^status,
        order_by: [desc: msg.message_id]
      )

    Repo.all(query, timeout: :infinity)
  end

  @doc """
    Retrieves the numbers of the L1 blocks containing the confirmation transactions
    bounding the first interval where missed confirmation transactions could be found.

    The absence of a confirmation transaction is assumed based on the analysis of a
    series of confirmed rollup blocks. For example, if blocks 0-3 are confirmed by transaction X,
    blocks 7-9 by transaction Y, and blocks 12-15 by transaction Z, there are two gaps:
    blocks 4-6 and 10-11. According to Arbitrum's nature, this indicates that the confirmation
    transactions for blocks 6 and 11 have not yet been indexed.

    In the example above, the function will return the tuple with the numbers of the L1 blocks
    where transactions Y and Z were included.

    ## Returns
    - A tuple of the L1 block numbers between which missing confirmation transactions are suspected,
      or `nil` if no gaps in confirmed blocks are found or if there are no missed confirmation transactions.
  """
  @spec l1_blocks_of_confirmations_bounding_first_unconfirmed_rollup_blocks_gap() ::
          {FullBlock.block_number() | nil, FullBlock.block_number()} | nil
  def l1_blocks_of_confirmations_bounding_first_unconfirmed_rollup_blocks_gap do
    # The first subquery retrieves the numbers of confirmed rollup blocks.
    rollup_blocks_query =
      from(
        rb in BatchBlock,
        inner_join: fb in FullBlock,
        on: rb.hash == fb.hash,
        select: %{
          block_num: fb.number,
          confirm_id: rb.confirm_id
        },
        where: not is_nil(rb.confirm_id)
      )

    # The second subquery builds on the first one, grouping block numbers by their
    # confirmation transactions. As a result, it identifies the starting and ending
    # rollup blocks for every transaction.
    confirmed_ranges_query =
      from(
        subquery in subquery(rollup_blocks_query),
        select: %{
          confirm_id: subquery.confirm_id,
          min_block_num: min(subquery.block_num),
          max_block_num: max(subquery.block_num)
        },
        group_by: subquery.confirm_id
      )

    # The third subquery utilizes the window function LAG to associate each confirmation
    # transaction with the starting rollup block of the preceding transaction.
    confirmed_combined_ranges_query =
      from(
        subquery in subquery(confirmed_ranges_query),
        select: %{
          confirm_id: subquery.confirm_id,
          min_block_num: subquery.min_block_num,
          max_block_num: subquery.max_block_num,
          prev_max_number: fragment("LAG(?, 1) OVER (ORDER BY ?)", subquery.max_block_num, subquery.min_block_num),
          prev_confirm_id: fragment("LAG(?, 1) OVER (ORDER BY ?)", subquery.confirm_id, subquery.min_block_num)
        }
      )

    # The final query identifies confirmation transactions for which the ending block does
    # not precede the starting block of the subsequent confirmation transaction.
    main_query =
      from(
        subquery in subquery(confirmed_combined_ranges_query),
        inner_join: tx_cur in LifecycleTransaction,
        on: subquery.confirm_id == tx_cur.id,
        left_join: tx_prev in LifecycleTransaction,
        on: subquery.prev_confirm_id == tx_prev.id,
        select: {tx_prev.block, tx_cur.block},
        where: subquery.min_block_num - 1 != subquery.prev_max_number or is_nil(subquery.prev_max_number),
        order_by: [desc: subquery.min_block_num],
        limit: 1
      )

    main_query
    |> Repo.one()
  end
end
