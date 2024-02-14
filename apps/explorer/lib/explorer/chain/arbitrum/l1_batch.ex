defmodule Explorer.Chain.Arbitrum.L1Batch do
  @moduledoc "Models an L1 batch for Arbitrum."

  use Explorer.Schema

  alias Explorer.Chain.{
    Block,
    Hash
  }

  alias Explorer.Chain.Arbitrum.LifecycleTransaction

  @required_attrs ~w(number tx_count start_block end_block before_acc after_acc commit_id)a

  @type t :: %__MODULE__{
          number: non_neg_integer(),
          tx_count: non_neg_integer(),
          start_block: Block.block_number(),
          end_block: Block.block_number(),
          before_acc: Hash.t(),
          after_acc: Hash.t(),
          commit_id: non_neg_integer(),
          commit_transaction: %Ecto.Association.NotLoaded{} | LifecycleTransaction.t() | nil
        }

  @primary_key {:number, :integer, autogenerate: false}
  schema "arbitrum_l1_batches" do
    field(:tx_count, :integer)
    field(:start_block, :integer)
    field(:end_block, :integer)
    field(:before_acc, Hash.Full)
    field(:after_acc, Hash.Full)

    belongs_to(:commit_transaction, LifecycleTransaction,
      foreign_key: :commit_id,
      references: :id,
      type: :integer
    )

    timestamps()
  end

  @doc """
    Validates that the `attrs` are valid.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Schema.t()
  def changeset(%__MODULE__{} = batches, attrs \\ %{}) do
    batches
    |> cast(attrs, @required_attrs)
    |> validate_required(@required_attrs)
    |> foreign_key_constraint(:commit_id)
    |> unique_constraint(:number)
  end
end
