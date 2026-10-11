defmodule Alnasl.Transport.Fake.Silent do
  @moduledoc "A device that never answers: a port with nothing on it."
  def handle(state, _bytes), do: {<<>>, state}
end
