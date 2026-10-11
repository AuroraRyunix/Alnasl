defmodule Alnasl.Driver.Replay do
  @moduledoc """
  A capture file played back as if the board were here: the same positions,
  clock readings and disconnections, at the pace they were recorded (or
  faster), into the same pipeline a live board feeds.

  Options (string keys): `"path"` - the capture file; `"speed"` (default 1).

  This is how a recording of a real board becomes a regression test, and how
  the bus driver gets finished: a capture written by `tools/serial_proxy.py`
  holds raw bytes only, and `Alnasl.Recorder.read/1` decodes them with the
  DGT protocol on the way in.
  """

  @behaviour Alnasl.Driver

  alias Alnasl.{Driver, Driver.Player, Recorder}

  @impl true
  def start_link(opts) do
    options = Keyword.get(opts, :options, %{})
    owner = Keyword.fetch!(opts, :owner)
    id = Keyword.fetch!(opts, :id)

    case Recorder.read(options["path"] || "") do
      {:ok, capture} ->
        speed = if is_number(options["speed"]), do: options["speed"], else: 1
        Player.start_link(owner: owner, id: id, events: capture.events, speed: speed)

      {:error, _reason} ->
        # A file that is gone is a board that does not answer.
        Driver.emit(owner, id, :disconnected)
        Player.start_link(owner: owner, id: id, events: [], speed: 1, connected: false)
    end
  end
end
