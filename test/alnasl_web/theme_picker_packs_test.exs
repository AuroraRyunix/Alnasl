defmodule AlnaslWeb.ThemePickerPacksTest do
  @moduledoc """
  Theme packs as a person meets them: in the rail's picker and Setup's grid,
  in the data the root layout hands `assets/js/theme.js`, and on the PIN
  page, which wears the theme too.
  """
  use AlnaslWeb.SiteCase

  # A refused pack is logged, which is the point and not this output's business.
  @moduletag :capture_log

  import Alnasl.ThemePackFixtures

  setup :themes_dir

  defp page(conn, path \\ ~p"/setup"),
    do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

  defp packs_data(doc) do
    doc
    |> LazyHTML.query(~s(meta[name="alnasl-theme-packs"]))
    |> LazyHTML.attribute("content")
    |> hd()
    |> Jason.decode!()
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "with no packs the pickers are the built-ins and the script gets an empty list", %{
    conn: conn
  } do
    doc = page(conn)

    assert packs_data(doc) == []
    assert count(doc, ".theme-picker-item.is-pack") == 0
    assert count(doc, ".theme-picker-refused") == 0
    assert count(doc, ~s(#theme-picker [data-theme-opt="contrast"])) == 1
  end

  test "an installed pack is offered after the built-ins in both pickers, with its swatch", %{
    conn: conn,
    themes_dir: dir
  } do
    install_pack(dir, "toon", meta: %{"name" => "Toon", "dark" => true})
    install_pack(dir, "evil", css: ~s(@import "x";))

    doc = page(conn)

    for picker <- ~w(theme-picker theme-grid) do
      assert count(doc, "##{picker}-pack-toon[data-theme-opt=toon]") == 1
      assert count(doc, "##{picker}-pack-toon .theme-pack-swatch i") == 3

      # After the built-ins: the last option of the picker is the pack.
      options =
        doc
        |> LazyHTML.query("##{picker} [data-theme-opt]")
        |> LazyHTML.attribute("data-theme-opt")

      assert List.last(options) == "toon"
      assert hd(options) == "system"

      # Refused, and said so where whoever installed it will look.
      assert count(doc, "##{picker}-refused-evil") == 1
      assert count(doc, "##{picker}-pack-evil") == 0
    end

    assert [%{"id" => "toon", "dark" => true, "css" => "/themes/toon/theme.css?v=" <> _}] =
             packs_data(doc)
  end

  test "the Dutch picker uses the pack's Dutch name", %{conn: conn, themes_dir: dir} do
    install_pack(dir, "toon", meta: %{"name" => "Toon", "name_nl" => "Tekenfilm"})
    Settings.put("locale", "nl")

    doc = page(conn)
    assert doc |> LazyHTML.query("#theme-grid-pack-toon") |> LazyHTML.text() =~ "Tekenfilm"
  end

  test "a pack that vanishes is no longer offered or known to the script", %{
    conn: conn,
    themes_dir: dir
  } do
    path = install_pack(dir, "toon")
    assert [_] = packs_data(page(conn))

    File.rm_rf!(path)
    doc = page(build_conn())
    assert packs_data(doc) == []
    assert count(doc, "#theme-picker-pack-toon") == 0
  end

  test "the PIN page knows the packs too", %{conn: conn, themes_dir: dir} do
    install_pack(dir, "toon")
    Settings.set_pin("2468")

    doc = page(%{conn | remote_ip: {10, 0, 0, 9}}, ~p"/unlock")
    assert [%{"id" => "toon"}] = packs_data(doc)
  end
end
