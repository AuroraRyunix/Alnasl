defmodule AlnaslWeb.ErrorHTMLTest do
  use AlnaslWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html: a sentence and the way back" do
    html = render_to_string(AlnaslWeb.ErrorHTML, "404", "html", [])
    assert html =~ ~s(id="error-title")
    assert html =~ ~s(id="error-home")
  end

  test "renders 500.html: a sentence and the way back" do
    html = render_to_string(AlnaslWeb.ErrorHTML, "500", "html", [])
    assert html =~ ~s(id="error-title")
    assert html =~ ~s(id="error-home")
  end

  test "any other status keeps the plain words" do
    assert render_to_string(AlnaslWeb.ErrorHTML, "410", "html", []) == "Gone"
  end
end
