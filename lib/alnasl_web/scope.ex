defmodule AlnaslWeb.Scope do
  @moduledoc """
  Which tournament a page is about, and the addresses that say so.

  A box with one tournament has the addresses it always had: `/round/3`,
  `/round/3/board/2`. A page about another tournament carries it in front:
  `/t/4/round/3/board/2`. The same goes for the ids of the elements a page
  is made of: `tile-2` on the box's own tournament, `tile-t4-2` on another,
  so that two tournaments on one screen do not share an id.
  """

  use AlnaslWeb, :verified_routes

  alias Alnasl.Tournaments

  @doc "The tournament the address names (`\"tid\"`), or the box's own."
  def tournament(params) do
    with text when is_binary(text) <- params["tid"],
         {id, ""} <- Integer.parse(text),
         %{} = tournament <- Tournaments.get(id) do
      tournament
    else
      _none -> Tournaments.default()
    end
  end

  @doc """
  The same, for an account: a tournament the account may not see is not
  found (`nil`), and an address that names none leads to the current
  hall's own tournament - the box's own for its own hall.
  """
  def tournament(params, account) do
    tournament = tournament(params)

    cond do
      Alnasl.Halls.sees?(account, tournament) -> tournament
      params["tid"] != nil -> nil
      hall_id = Alnasl.Accounts.Scope.hall_id(account) -> Alnasl.Halls.local_tournament(hall_id)
      true -> nil
    end
  end

  defp own?(nil), do: true
  defp own?(id), do: id == Tournaments.default_id()

  def round_path(tournament_id, round) do
    if own?(tournament_id),
      do: ~p"/round/#{round}",
      else: ~p"/t/#{tournament_id}/round/#{round}"
  end

  def game_path(tournament_id, round, board_no) do
    if own?(tournament_id),
      do: ~p"/round/#{round}/board/#{board_no}",
      else: ~p"/t/#{tournament_id}/round/#{round}/board/#{board_no}"
  end

  def round_file(tournament_id, round) do
    if own?(tournament_id),
      do: ~p"/files/round/#{round}",
      else: ~p"/files/t/#{tournament_id}/round/#{round}"
  end

  def game_file(tournament_id, round, board_no, game_no \\ nil) do
    base =
      if own?(tournament_id),
        do: ~p"/files/round/#{round}/board/#{board_no}",
        else: ~p"/files/t/#{tournament_id}/round/#{round}/board/#{board_no}"

    if game_no, do: base <> "?game=#{game_no}", else: base
  end

  @doc "The part of an element id that says which board of which tournament: `2`, `t4-2`."
  def dom(tournament_id, board_no) do
    if own?(tournament_id), do: "#{board_no}", else: "t#{tournament_id}-#{board_no}"
  end
end
