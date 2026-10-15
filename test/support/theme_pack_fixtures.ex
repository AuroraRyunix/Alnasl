defmodule Alnasl.ThemePackFixtures do
  @moduledoc """
  Theme packs in a temporary folder, and the application pointed at it.
  Tests using `themes_dir/1` change application config, so they run
  `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  A fresh, empty themes folder, set as `:themes_dir` for the rest of the test
  and removed afterwards.
  """
  def themes_dir(_context \\ %{}) do
    dir = Path.join(System.tmp_dir!(), "alnasl-themes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:alnasl, :themes_dir)
    Application.put_env(:alnasl, :themes_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:alnasl, :themes_dir, previous),
        else: Application.delete_env(:alnasl, :themes_dir)

      File.rm_rf(dir)
    end)

    %{themes_dir: dir}
  end

  @doc "A pack's `theme.css` that passes the scanner."
  def good_css(id) do
    """
    /* a comment with @import in it is only a comment */
    [data-theme="#{id}"] {
      --bg: #f7f6f3;
      --ink: #24211c;
    }
    [data-theme="#{id}"] .panel { border: 2px solid #000; content: "}"; }
    """
  end

  @doc """
  Writes the pack `id` into `dir`. Options: `:css` (the stylesheet), `:meta`
  (merged over a valid theme.json), `:fonts` (`%{name => binary}`).
  """
  def install_pack(dir, id, opts \\ []) do
    path = Path.join(dir, id)
    File.mkdir_p!(path)

    meta =
      Map.merge(
        %{
          "id" => id,
          "name" => "Pack #{id}",
          "author" => "Somebody",
          "version" => "1.0.0",
          "dark" => false,
          "swatch" => ["#112233", "#ffd22e", "#ffffff"]
        },
        Keyword.get(opts, :meta, %{})
      )

    File.write!(Path.join(path, "theme.json"), Jason.encode!(meta))
    File.write!(Path.join(path, "theme.css"), Keyword.get(opts, :css, good_css(id)))

    for {name, data} <- Keyword.get(opts, :fonts, %{}) do
      File.mkdir_p!(Path.join(path, "fonts"))
      File.write!(Path.join([path, "fonts", name]), data)
    end

    path
  end
end
