defmodule Alnasl.Updates.Checker do
  @moduledoc """
  Asks, every half hour, whether a newer Alnasl is out, and remembers the
  answer for the pages (`current/0`).

  One request a time, with the ETag of the last answer: GitHub answers
  "nothing changed" with a 304 that costs nothing against the sixty
  unauthenticated requests an hour a hall's address has. The first question
  comes a minute after start, when the boards have had their turn.

  It asks only while the setting says `"ask"` (`Alnasl.Updates.mode/0`), and
  a failure is not remembered as anything: what was known stays known, and
  the next turn asks again. `check_now/0` is the button on Setup, which asks
  whatever the setting says - a person pressing a button is not the box
  doing something by itself.

  The answer is kept in `:persistent_term`: every page reads it when it
  opens, and it changes a few times a year.
  """

  use GenServer

  alias Alnasl.Updates

  @first_ms 60_000
  @every_ms 30 * 60_000
  @key {__MODULE__, :available}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The newer release last heard of, or `nil`."
  def current, do: :persistent_term.get(@key, nil)

  @doc """
  Asks now. `{:ok, info}`, `:current` or `:error` - the last of which the
  button, unlike the timer, does say out loud.
  """
  def check_now, do: GenServer.call(__MODULE__, :check_now, 20_000)

  @doc "Forgets what was heard, and the ETag it was heard with (tests)."
  def forget, do: GenServer.call(__MODULE__, :forget)

  @doc "Puts an answer in place without asking anybody (tests)."
  def put(info) do
    :persistent_term.put(@key, info)
    Updates.broadcast()
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :timer, true), do: Process.send_after(self(), :tick, @first_ms)
    {:ok, %{etag: nil, timer: Keyword.get(opts, :timer, true)}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = if Updates.mode() == "ask", do: elem(ask(state), 1), else: state
    if state.timer, do: Process.send_after(self(), :tick, @every_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:check_now, _from, state) do
    # Unconditional: the button wants an answer, not "as before".
    {answer, state} = ask(%{state | etag: nil})
    {:reply, answer, state}
  end

  def handle_call(:forget, _from, state) do
    :persistent_term.erase(@key)
    {:reply, :ok, %{state | etag: nil}}
  end

  defp ask(state) do
    case Updates.check(state.etag) do
      {:ok, info, etag} ->
        remember(info)
        {{:ok, info}, %{state | etag: etag}}

      {:current, etag} ->
        remember(nil)
        {:current, %{state | etag: etag}}

      :not_modified ->
        {if(current(), do: {:ok, current()}, else: :current), state}

      :error ->
        {:error, state}
    end
  end

  defp remember(info) do
    if info != current() do
      if info, do: :persistent_term.put(@key, info), else: :persistent_term.erase(@key)
      Updates.broadcast()
    end
  end
end
