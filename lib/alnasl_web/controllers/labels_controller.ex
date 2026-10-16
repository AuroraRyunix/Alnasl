defmodule AlnaslWeb.LabelsController do
  @moduledoc """
  The stickers: a page to print and cut up, one label a board - the table
  number large, and under it what the board is known by, so that a label
  that has come off can be put back on the right board.
  """

  use AlnaslWeb, :controller

  alias Alnasl.Boards

  def index(conn, _params) do
    # The labels of the hall the pages are about.
    all = Alnasl.Halls.here(conn.assigns.current_scope, Boards.list())

    boards =
      all
      |> Enum.filter(&(&1.table_no != nil))
      |> Enum.sort_by(& &1.table_no)

    without = Enum.count(all, &(&1.table_no == nil))

    render(conn, :index,
      boards: boards,
      without: without,
      box: Alnasl.Settings.get("box_name") || "Alnasl",
      page_title: gettext("Table labels")
    )
  end
end
