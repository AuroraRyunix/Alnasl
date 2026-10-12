defmodule Alnasl.ResultsSite do
  @moduledoc """
  Where a tournament can be looked at on the results site: the addresses a
  spectator uses, worked out from the site's address and the tournament's
  short name, which the box has anyway.

  Only routes OpenResults has (its router, `docs/live-boards-api.md`):

  | page | route |
  |---|---|
  | the tournament | `/t/:slug` |
  | the live boards, all rounds | `/t/:slug/live` |
  | the live boards of a round | `/t/:slug/live/:round` |
  | one board, live | `/t/:slug/live/:round/:board` |
  | the PGN of a round | `/t/:slug/live/:round/pgn` |
  | the PGN of one board | `/t/:slug/live/:round/:board/pgn` |

  Pure functions: a tournament (or any map with `server_url` and `slug`)
  in, an address out. `nil` where there is nothing to link to; `why_not/1`
  says what is missing.
  """

  @doc "The site's address without a trailing slash, or `nil` when there is none (or it is not a web address)."
  def root(%{server_url: url}), do: root(url)

  def root(url) when is_binary(url) do
    url = url |> String.trim() |> String.trim_trailing("/")

    %URI{scheme: scheme, host: host} = URI.parse(url)
    if scheme in ["http", "https"] and host not in [nil, ""], do: url
  end

  def root(_none), do: nil

  @doc "The tournament's short name, or `nil`."
  def slug(%{slug: slug}) when is_binary(slug) do
    case String.trim(slug) do
      "" -> nil
      slug -> slug
    end
  end

  def slug(_none), do: nil

  @doc "Has this tournament a page on a results site: an address and a short name?"
  def page?(tournament), do: root(tournament) != nil and slug(tournament) != nil

  @doc """
  What is missing for a link: `nil` when nothing, else `:no_site` (no
  address - or one that is not a web address) or `:no_slug` (no short name).
  """
  def why_not(tournament) do
    cond do
      root(tournament) == nil -> :no_site
      slug(tournament) == nil -> :no_slug
      true -> nil
    end
  end

  @doc "The tournament's page."
  def tournament_url(tournament), do: under(tournament, "")

  @doc "The live boards, all rounds."
  def live_url(tournament), do: under(tournament, "/live")

  @doc "The live boards of a round."
  def round_url(tournament, round) when is_integer(round) and round > 0,
    do: under(tournament, "/live/#{round}")

  def round_url(_tournament, _round), do: nil

  @doc "One board, live."
  def board_url(tournament, round, board)
      when is_integer(round) and round > 0 and is_integer(board) and board > 0,
      do: under(tournament, "/live/#{round}/#{board}")

  def board_url(_tournament, _round, _board), do: nil

  @doc "The PGN of a round."
  def round_pgn_url(tournament, round) when is_integer(round) and round > 0,
    do: under(tournament, "/live/#{round}/pgn")

  def round_pgn_url(_tournament, _round), do: nil

  @doc "The PGN of one board."
  def board_pgn_url(tournament, round, board)
      when is_integer(round) and round > 0 and is_integer(board) and board > 0,
      do: under(tournament, "/live/#{round}/#{board}/pgn")

  def board_pgn_url(_tournament, _round, _board), do: nil

  @doc "The address as people say it: `\"results.example.org/t/open\"`, for a link's text."
  def display(tournament) do
    case tournament_url(tournament) do
      nil -> nil
      url -> String.replace(url, ~r{^https?://}, "")
    end
  end

  # A slug is one path segment: whatever is not safe in one is escaped,
  # a slash included.
  defp under(tournament, path) do
    with root when is_binary(root) <- root(tournament),
         slug when is_binary(slug) <- slug(tournament) do
      root <> "/t/" <> URI.encode(slug, &URI.char_unreserved?/1) <> path
    else
      _nothing -> nil
    end
  end
end
