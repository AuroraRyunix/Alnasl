defmodule AlnaslWeb.ErrorHTML do
  @moduledoc """
  What a browser is shown when a page is not there (404) or broke (500):
  a sentence and the way back to the live page, instead of two bare words
  and a dead end. Self-contained on purpose - the page that broke may be
  the layout.
  """
  use AlnaslWeb, :html

  def render("404.html", assigns), do: page(Map.put(assigns, :kind, :not_found))
  def render("500.html", assigns), do: page(Map.put(assigns, :kind, :broke))

  # Any other status keeps Phoenix's plain words.
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)

  defp page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>
          {if @kind == :not_found, do: gettext("Not found"), else: gettext("Something broke")}
        </title>
      </head>
      <body style="font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem">
        <h1 id="error-title">
          {if @kind == :not_found, do: gettext("Not found"), else: gettext("Something broke")}
        </h1>
        <p id="error-text">
          {if @kind == :not_found,
            do:
              gettext(
                "There is no such page here. A link may be old, or a game, board or round may have been removed."
              ),
            else:
              gettext(
                "Alnasl could not show this page. Nothing was lost: the boards keep being read. Try again, and look in the Log if it repeats."
              )}
        </p>
        <p><a id="error-home" href={~p"/"}>{gettext("Back to the live page")}</a></p>
      </body>
    </html>
    """
  end
end
