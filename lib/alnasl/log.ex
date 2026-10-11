defmodule Alnasl.Log do
  @moduledoc """
  The arbiter's log: board connected, move recovered, out of sync, repaired,
  offline, sent. Each line is a `kind` and its data; the sentence is made
  where it is shown (`AlnaslWeb.LogText`), so the log reads in whichever
  language the site is in today.

  Not the application log. This one is for a person standing at the box
  asking "what happened on board 7".
  """

  import Ecto.Query

  alias Alnasl.Log.Event
  alias Alnasl.Repo

  @topic "log"
  @levels ~w(info warn error)

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  @doc """
  Writes a line. `ref` says what it is about: `%{board_id, round, board_no}`,
  any of them. A failure to write the log is never a reason to stop.
  """
  def add(level, kind, data \\ %{}, ref \\ %{}) when level in [:info, :warn, :error] do
    event = %Event{
      at: DateTime.utc_now(),
      level: Atom.to_string(level),
      kind: to_string(kind),
      board_id: ref[:board_id],
      round: ref[:round],
      board_no: ref[:board_no],
      data: Jason.encode!(data)
    }

    try do
      event = Repo.insert!(event)
      Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:log, event})
      event
    rescue
      _error -> event
    catch
      :exit, _reason -> event
    end
  end

  @doc "The newest lines first. Filters: `:level` (that level and worse), `:kind`, `:board_no`, `:limit`."
  def list(filters \\ []) do
    Event
    |> order_by([e], desc: e.at, desc: e.id)
    |> limit(^Keyword.get(filters, :limit, 300))
    |> filter_level(filters[:level])
    |> filter_kind(filters[:kind])
    |> filter_board(filters[:board_no])
    |> Repo.all()
  end

  defp filter_level(query, level) when level in ["warn", :warn], do: where(query, [e], e.level in ["warn", "error"])
  defp filter_level(query, level) when level in ["error", :error], do: where(query, [e], e.level == "error")
  defp filter_level(query, _all), do: query

  defp filter_kind(query, kind) when is_binary(kind) and kind != "", do: where(query, [e], like(e.kind, ^(kind <> "%")))
  defp filter_kind(query, _all), do: query

  defp filter_board(query, no) when is_integer(no), do: where(query, [e], e.board_no == ^no)
  defp filter_board(query, _all), do: query

  def levels, do: @levels

  @doc "The data of a line as a map with string keys."
  def data(%Event{data: nil}), do: %{}
  def data(%Event{data: json}), do: Jason.decode!(json)

  @doc "Removes all but the newest `keep` lines."
  def prune(keep \\ 20_000) do
    case Repo.one(from e in Event, order_by: [desc: e.id], offset: ^keep, limit: 1, select: e.id) do
      nil -> 0
      id -> Repo.delete_all(from e in Event, where: e.id <= ^id) |> elem(0)
    end
  end
end
