defmodule Alnasl.LinkHelpers do
  @moduledoc """
  For tests of the link with OpenPairings: the fake pairing program started
  and put behind the box's requests, and a tournament on it reached by a
  connect code the box has taken.
  """

  alias Alnasl.{FakeOpenPairings, OpenPairings, Repo, Tournaments}
  alias Alnasl.Tournaments.Tournament

  @doc "Starts the fake pairing program for this test."
  def pairing_program do
    ExUnit.Callbacks.start_supervised!(FakeOpenPairings)
    FakeOpenPairings.install()
    ExUnit.Callbacks.on_exit(fn -> FakeOpenPairings.uninstall() end)
    :ok
  end

  @doc """
  A tournament `id` on the fake pairing program, and its connect code added
  to the box. Returns the box's row of it.
  """
  def linked(id, opts \\ []) do
    FakeOpenPairings.add_tournament(id, opts)
    {:ok, _link, _found} = OpenPairings.add_code(FakeOpenPairings.code(id))
    by_remote(id)
  end

  @doc "The box's row of the pairing program's tournament `id`."
  def by_remote(id), do: Repo.get_by(Tournament, remote_id: id)

  @doc "Asks the pairing program once more, as the poller would."
  def poll do
    OpenPairings.poll_all()
    :ok
  end

  @doc "The box's row again, as it is now."
  def again(%Tournament{id: id}), do: Tournaments.get(id)
end
