defmodule Alnasl.ThemePacksTest do
  use ExUnit.Case, async: false

  # A refused pack is logged, which is the point and not this output's business.
  @moduletag :capture_log

  import Alnasl.ThemePackFixtures

  alias Alnasl.ThemePacks
  alias AlnaslWeb.ThemeContrast

  describe "where packs come from" do
    test "ALNASL_THEMES_DIR wins; otherwise the data folder's themes" do
      assert ThemePacks.resolve_dir("/srv/themes", "/var/lib/alnasl") == "/srv/themes"

      assert ThemePacks.resolve_dir(nil, "/var/lib/alnasl") ==
               Path.join("/var/lib/alnasl", "themes")

      assert ThemePacks.resolve_dir("", "/var/lib/alnasl") ==
               Path.join("/var/lib/alnasl", "themes")
    end

    test "nothing is installed by default, and nothing is created to install it in" do
      previous = Application.get_env(:alnasl, :themes_dir)
      Application.delete_env(:alnasl, :themes_dir)

      try do
        assert ThemePacks.dir() == Path.join(Application.fetch_env!(:alnasl, :data_dir), "themes")
        assert ThemePacks.list() == []
        assert ThemePacks.refused() == []
        assert ThemePacks.bootstrap_json() == "[]"
        refute File.exists?(ThemePacks.dir())
      after
        if previous, do: Application.put_env(:alnasl, :themes_dir, previous)
      end
    end

    test "no pack may take the name of a built-in theme" do
      keys = Enum.map(AlnaslWeb.Layouts.themes(), &elem(&1, 0))
      assert keys -- ThemePacks.builtin_ids() == []
      # The two words the first light/dark switch stored, which theme.js
      # still turns into paper and night.
      assert "light" in ThemePacks.builtin_ids()
      assert "dark" in ThemePacks.builtin_ids()
    end
  end

  describe "the bundled packs" do
    setup do
      previous = Application.get_env(:alnasl, :bundled_themes_dir)
      Application.delete_env(:alnasl, :bundled_themes_dir)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:alnasl, :bundled_themes_dir, previous),
          else: Application.delete_env(:alnasl, :bundled_themes_dir)
      end)
    end

    test "live in the program's priv folder" do
      assert ThemePacks.bundled_dir() ==
               Path.join(to_string(:code.priv_dir(:alnasl)), "theme_packs")

      assert File.dir?(Path.join(ThemePacks.bundled_dir(), "toon"))
    end

    test "Toon is listed with no themes folder at all" do
      previous = Application.get_env(:alnasl, :themes_dir)
      Application.delete_env(:alnasl, :themes_dir)

      try do
        refute File.exists?(ThemePacks.dir())
        assert [%{id: "toon", name: "Toon", dark: false, path: path}] = ThemePacks.list()
        assert path == Path.join(ThemePacks.bundled_dir(), "toon")
        assert ThemePacks.refused() == []
        assert File.regular?(Path.join(path, "fonts/OFL.txt"))
        refute File.exists?(ThemePacks.dir())
      after
        if previous, do: Application.put_env(:alnasl, :themes_dir, previous)
      end
    end

    test "passes the scanner and the contrast check" do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      assert {:ok, %{id: "toon"}} = ThemePacks.load(Path.join(ThemePacks.bundled_dir(), "toon"))
      Mix.Tasks.Alnasl.ThemeCheck.run(["--bundled"])
      assert_received {:mix_shell, :info, ["toon: scan passed (light)"]}
      assert_received {:mix_shell, :info, ["toon: contrast passed" <> _]}
    end

    test "every font its stylesheet names is in the pack" do
      path = Path.join(ThemePacks.bundled_dir(), "toon")
      css = File.read!(Path.join(path, "theme.css"))

      for [_, file] <- Regex.scan(~r/url\("fonts\/([^"]+)"\)/, css) do
        assert File.regular?(Path.join([path, "fonts", file])), file
      end
    end

    test "a user pack of the same id wins" do
      %{themes_dir: dir} = themes_dir()
      install_pack(dir, "toon", meta: %{"name" => "My Toon"})
      install_pack(dir, "owl")

      assert [%{id: "owl"}, %{id: "toon", name: "My Toon", path: path}] =
               Enum.sort_by(ThemePacks.list(), & &1.id)

      assert path == Path.join(dir, "toon")
      assert ThemePacks.get("toon").name == "My Toon"
    end

    test "bundled and user packs are listed together" do
      %{themes_dir: dir} = themes_dir()
      install_pack(dir, "owl")
      assert Enum.sort(ThemePacks.ids()) == ["owl", "toon"]
    end
  end

  describe "an installed pack" do
    setup :themes_dir

    test "is listed, labelled and served at a versioned URL", %{themes_dir: dir} do
      install_pack(dir, "toon",
        meta: %{"name" => "Toon", "name_nl" => "Tekenfilm", "dark" => true}
      )

      assert [%{id: "toon", name: "Toon", dark: true} = pack] = ThemePacks.list()
      assert ThemePacks.label(pack, "nl") == "Tekenfilm"
      assert ThemePacks.label(pack, "en") == "Toon"
      assert ThemePacks.css_url(pack) =~ ~r/\A\/themes\/toon\/theme\.css\?v=[0-9a-f]{16}\z/
      assert ThemePacks.get("toon") == pack

      assert [%{"id" => "toon", "dark" => true, "css" => "/themes/toon/theme.css?v=" <> _}] =
               Jason.decode!(ThemePacks.bootstrap_json())
    end

    test "is gone the moment its folder is", %{themes_dir: dir} do
      path = install_pack(dir, "toon")
      assert ThemePacks.ids() == ["toon"]

      File.rm_rf!(path)
      assert ThemePacks.ids() == []
      assert ThemePacks.get("toon") == nil
    end

    test "changed in place is read again, with a new version on its URL", %{themes_dir: dir} do
      install_pack(dir, "toon")
      [before] = ThemePacks.list()

      install_pack(dir, "toon",
        css: good_css("toon") <> "\n[data-theme=\"toon\"] h1 { margin: 0; }"
      )

      [later] = ThemePacks.list()
      assert later.etag != before.etag
    end

    test "for some accounts only is everybody's here: the box has no accounts", %{
      themes_dir: dir
    } do
      install_pack(dir, "mine", meta: %{"users" => ["someone@example.org"]})
      install_pack(dir, "odd", meta: %{"users" => []})

      assert ThemePacks.ids() == ["mine", "odd"]
      assert ThemePacks.refused() == []
    end

    test "is refused, with the reason, when its CSS is not safe", %{themes_dir: dir} do
      install_pack(dir, "evil", css: ~s(@import "https://evil/x.css";))
      install_pack(dir, "loose", css: "body { color: red; }")

      assert ThemePacks.list() == []
      refused = Map.new(ThemePacks.refused())
      assert refused["evil"] =~ "@import"
      assert refused["loose"] =~ "scoped"
      assert ThemePacks.get("evil") == nil
    end

    test "is refused when theme.json is wrong", %{themes_dir: dir} do
      install_pack(dir, "a", meta: %{"id" => "b"}, css: good_css("b"))
      install_pack(dir, "paper", meta: %{"id" => "paper"})
      install_pack(dir, "light", meta: %{"id" => "light"})
      install_pack(dir, "c", meta: %{"swatch" => ["red", "#fff", "#000"]})
      install_pack(dir, "d", meta: %{"dark" => "yes"})
      install_pack(dir, "e", meta: %{"name" => String.duplicate("x", 41)})
      File.mkdir_p!(Path.join(dir, "Bad Name"))

      refused = Map.new(ThemePacks.refused())
      assert refused["a"] =~ "folder"
      assert refused["paper"] =~ "built-in"
      assert refused["light"] =~ "built-in"
      assert refused["c"] =~ "swatch"
      assert refused["d"] =~ "dark"
      assert refused["e"] =~ "name"
      assert refused["Bad Name"] =~ "theme.json"
      assert ThemePacks.list() == []
    end

    test "is refused when its stylesheet is over the cap", %{themes_dir: dir} do
      filler = "/*" <> String.duplicate("x", ThemePacks.css_limit()) <> "*/"
      install_pack(dir, "big", css: good_css("big") <> filler)

      assert [{"big", reason}] = ThemePacks.refused()
      assert reason =~ "200 KB"
    end
  end

  describe "the contrast a pack is held to" do
    setup do
      core = File.read!("assets/css/app.css")
      [_, night] = Regex.run(~r/:root\[data-theme="night"\]\s*\{(.*?)\n\}/s, core)
      %{core: core, night: night}
    end

    test "a pack with the Night palette passes, as Night does", %{core: core, night: night} do
      css = "[data-theme=\"owl\"] {#{night}\n}\n"
      assert ThemeContrast.pack_failures(core, css, "owl") == []
    end

    test "a pack that leaves out a token is told which", %{core: core, night: night} do
      css = "[data-theme=\"owl\"] {#{String.replace(night, ~r/\s*--guessed-bg:[^;]+;/, "")}\n}"
      # Left out, it is Paper's light pink under Night's light red: said
      # once as what is missing and once as what that does to the text.
      assert [missing, unreadable] = ThemeContrast.pack_failures(core, css, "owl")
      assert missing =~ "--guessed-bg is not defined"
      assert unreadable =~ "--guessed on --guessed-bg"
    end

    test "unreadable tokens and unreadable rules are both found", %{core: core, night: night} do
      css =
        "[data-theme=\"owl\"] {#{String.replace(night, ~r/--quiet:[^;]+;/, "--quiet: #33353a;")}\n}\n" <>
          "[data-theme=\"owl\"] .rail { background: #0a1747; color: #1d40c8; }\n" <>
          "[data-theme=\"owl\"] .bar { background: var(--panel); color: var(--ink); }\n"

      failures = ThemeContrast.pack_failures(core, css, "owl")
      assert Enum.any?(failures, &(&1 =~ "--quiet on --bg"))
      assert Enum.any?(failures, &(&1 =~ ".rail: its text on its background"))
      refute Enum.any?(failures, &(&1 =~ ".bar"))
    end

    test "a stylesheet without a token block is not a theme", %{core: core} do
      assert ["no [data-theme=\"owl\"]" <> _] =
               ThemeContrast.pack_failures(core, "[data-theme=\"owl\"] h1 { margin: 0; }", "owl")
    end
  end

  describe "mix alnasl.theme_check" do
    setup :themes_dir

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      :ok
    end

    test "passes a sound pack and says so", %{themes_dir: dir} do
      [_, night] =
        Regex.run(
          ~r/:root\[data-theme="night"\]\s*\{(.*?)\n\}/s,
          File.read!("assets/css/app.css")
        )

      path =
        install_pack(dir, "owl",
          meta: %{"dark" => true},
          css: "[data-theme=\"owl\"] {#{night}\n}\n"
        )

      Mix.Tasks.Alnasl.ThemeCheck.run([path])

      assert_received {:mix_shell, :info, ["owl: scan passed (dark)"]}
      assert_received {:mix_shell, :info, ["owl: contrast passed" <> _]}
    end

    test "fails a refused pack, and a pack nobody can read", %{themes_dir: dir} do
      evil = install_pack(dir, "evil", css: ~s(@import "x";))
      assert catch_exit(Mix.Tasks.Alnasl.ThemeCheck.run([evil])) == {:shutdown, 1}
      assert_received {:mix_shell, :error, ["refused: @import is not allowed"]}

      thin = install_pack(dir, "thin")
      assert catch_exit(Mix.Tasks.Alnasl.ThemeCheck.run([thin])) == {:shutdown, 1}
      assert_received {:mix_shell, :error, ["--panel is not defined" <> _]}
    end
  end
end
