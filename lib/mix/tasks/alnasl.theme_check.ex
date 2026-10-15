defmodule Mix.Tasks.Alnasl.ThemeCheck do
  @shortdoc "Checks a theme pack: safety scan, then the contrast every theme is held to"

  @moduledoc """
  Checks a theme pack folder before it is installed anywhere:

      mix alnasl.theme_check path/to/my-theme

  `mix alnasl.theme_check --bundled` checks every pack shipped inside the
  program (`priv/theme_packs`, see `Alnasl.ThemePacks.bundled_dir/0`), which
  is what CI and a release should do before the pack goes out.

  Two passes, the same two the program and its tests apply:

    1. `Alnasl.ThemePacks.load/1` - `theme.json` is complete, `theme.css` is
       under 200 KB, and `Alnasl.ThemePacks.Scanner` finds nothing it
       refuses (no `@import`, no URL but the pack's own `fonts/*.woff2`,
       every rule scoped to `[data-theme="<id>"]`). A pack that fails here
       is refused by the site as well.
    2. `AlnaslWeb.ThemeContrast.pack_failures/3` - the whole palette is
       defined, every text pairing the built-in themes are held to
       (`test/alnasl_web/accessibility_test.exs`) reaches 4.5:1, and so does
       every rule of the pack's own that sets a colour and a background
       together. The site would load a pack that fails here; this is where
       its author finds out that nobody can read it.

  Prints every failure and exits non-zero if there is one. Reads the site's
  stylesheet from `assets/css/app.css`, so run it from the repository.
  """

  use Mix.Task

  alias Alnasl.ThemePacks
  alias AlnaslWeb.ThemeContrast

  @impl Mix.Task
  def run(["--bundled"]) do
    Mix.Task.run("compile")
    dir = ThemePacks.bundled_dir()

    folders =
      case File.ls(dir) do
        {:ok, entries} -> entries |> Enum.sort() |> Enum.map(&Path.join(dir, &1))
        _ -> []
      end
      |> Enum.filter(&File.dir?/1)

    if folders == [], do: Mix.raise("no bundled packs in #{dir}")
    Enum.each(folders, &check/1)
  end

  def run([path]) do
    Mix.Task.run("compile")
    check(path)
  end

  def run(_), do: Mix.raise("usage: mix alnasl.theme_check PATH | --bundled")

  defp check(path) do
    case ThemePacks.load(path) do
      {:error, reason} ->
        Mix.shell().error("refused: #{reason}")
        exit({:shutdown, 1})

      {:ok, pack} ->
        Mix.shell().info("#{pack.id}: scan passed (#{if pack.dark, do: "dark", else: "light"})")
        core = File.read!(Path.join(File.cwd!(), "assets/css/app.css"))
        css = File.read!(Path.join(path, "theme.css"))

        case ThemeContrast.pack_failures(core, css, pack.id) do
          [] ->
            Mix.shell().info(
              "#{pack.id}: contrast passed (#{length(ThemeContrast.pairs())} pairings, and the pack's own rules)"
            )

          failures ->
            Enum.each(failures, fn failure -> Mix.shell().error(failure) end)
            Mix.shell().error("#{length(failures)} failure(s)")
            exit({:shutdown, 1})
        end
    end
  end
end
