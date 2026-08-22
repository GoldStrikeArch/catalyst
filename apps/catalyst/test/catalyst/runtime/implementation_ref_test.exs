defmodule Catalyst.Runtime.ImplementationRefTest do
  use ExUnit.Case, async: true

  alias Catalyst.Runtime.ImplementationRef

  test "process references keep topology out of logical identity" do
    first = ImplementationRef.process(:engine, :first_server, :engine_v1)
    second = ImplementationRef.process(:engine, :second_server, :engine_v1)

    assert ImplementationRef.transport(first) == :process
    assert ImplementationRef.target(first) == %{server: :first_server, protocol: :engine_v1}
    assert ImplementationRef.digest_term(first) == ImplementationRef.digest_term(second)
  end
end
