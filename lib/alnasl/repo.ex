defmodule Alnasl.Repo do
  use Ecto.Repo,
    otp_app: :alnasl,
    adapter: Ecto.Adapters.SQLite3
end
