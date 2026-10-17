defmodule AlnaslWeb.Components.Pager do
  @moduledoc """
  Lists with an end: fifty rows a page, a search, and the buttons between
  pages. A page keeps its list in memory (the log reads at most a couple of
  thousand lines, the recordings are a directory listing) and `slice/3`
  hands back one page of it; the buttons send a `"page"` event with the page
  to go to.
  """
  use Phoenix.Component
  use Gettext, backend: AlnaslWeb.Gettext

  @per_page 50

  def per_page, do: @per_page

  @doc """
  `{rows, page, pages}`: the rows of page `page` (1 up), with the page
  brought into range - a list that shrank under the reader lands on its
  last page, never on an empty one.
  """
  def slice(rows, page, per \\ @per_page) do
    pages = max(div(length(rows) + per - 1, per), 1)
    page = page |> max(1) |> min(pages)
    {rows |> Enum.drop((page - 1) * per) |> Enum.take(per), page, pages}
  end

  @doc "A page number out of an event's text; 1 for anything else."
  def page(text) do
    case Integer.parse(to_string(text)) do
      {n, ""} when n > 0 -> n
      _bad -> 1
    end
  end

  @doc "Does `text` occur in any of `haystacks`, ignoring case? An empty search matches everything."
  def match?(haystacks, search) do
    case search |> to_string() |> String.trim() |> String.downcase() do
      "" -> true
      needle -> Enum.any?(haystacks, &String.contains?(String.downcase(to_string(&1)), needle))
    end
  end

  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :pages, :integer, required: true
  attr :total, :integer, required: true

  def pager(assigns) do
    ~H"""
    <nav :if={@pages > 1} id={@id} class="pager" aria-label={gettext("Pages")}>
      <button
        id={@id <> "-prev"}
        type="button"
        class="btn small"
        phx-click="page"
        phx-value-to={@page - 1}
        disabled={@page <= 1}
      >
        {gettext("Previous")}
      </button>
      <span id={@id <> "-where"} class="note">
        {gettext("Page %{page} of %{pages} (%{total} in all)",
          page: @page,
          pages: @pages,
          total: @total
        )}
      </span>
      <button
        id={@id <> "-next"}
        type="button"
        class="btn small"
        phx-click="page"
        phx-value-to={@page + 1}
        disabled={@page >= @pages}
      >
        {gettext("Next")}
      </button>
    </nav>
    """
  end
end
