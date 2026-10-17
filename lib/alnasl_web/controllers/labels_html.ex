defmodule AlnaslWeb.LabelsHTML do
  @moduledoc "The printable sheet of table labels."

  use AlnaslWeb, :html

  alias AlnaslWeb.TableWords

  def index(assigns) do
    ~H"""
    <main id="labels" class="labels">
      <header class="labels-head">
        <h1>{gettext("Table labels")}</h1>
        <p class="note">
          {gettext(
            "Print this page (Ctrl+P), cut the labels apart and stick each on its board. The small line is what Alnasl knows the board by."
          )}
        </p>
        <p :if={@without > 0} id="labels-without" class="note">
          {gettext("%{n} board(s) have no table number yet and are not on this sheet.",
            n: @without
          )}
        </p>
        <a id="labels-back" class="btn small" href={~p"/boards"}>{gettext("Back to Boards")}</a>
      </header>
      <div :if={@boards == []} id="labels-empty" class="empty">
        <b>{gettext("No labels to print")}</b>
        <p>{gettext("No board has a table number yet. Number them on the Boards page first.")}</p>
      </div>
      <ul :if={@boards != []} id="labels-sheet" class="labels-sheet">
        <li :for={board <- @boards} id={"label-#{board.id}"} class="label">
          <span class="label-word">{gettext("Table")}</span>
          <b class="label-number">{board.table_no}</b>
          <span class="label-id">{TableWords.identity(board)}</span>
          <span class="label-box">{@box} · {board.name}</span>
        </li>
      </ul>
    </main>
    """
  end
end
