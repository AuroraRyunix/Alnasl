defmodule Alnasl do
  @moduledoc """
  Alnasl keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  Which program this is: `:box`, a computer in a hall with serial ports,
  an installer and a PIN, or `:server`, the hosted copy
  (`ALNASL_NO_LOCAL_BOARDS`) whose boards all come from bridges. The one
  place that is decided; `Alnasl.Accounts.server?/0` and
  `Alnasl.Boards.local?/0` only read it.
  """
  @spec edition() :: :box | :server
  def edition do
    if Application.get_env(:alnasl, :local_boards, true), do: :box, else: :server
  end
end
