defmodule Catalyst.Extensions.ModuleScanTest do
  use ExUnit.Case, async: true

  alias Catalyst.Extensions.ModuleScan

  doctest ModuleScan

  test "finds nested and absolute modules in source order" do
    source = ~S'''
    defmodule Scan.Parent do
      defmodule Child do
      end

      defmodule Elixir.Scan.Absolute do
      end
    end
    '''

    assert ModuleScan.modules(source) == [Scan.Parent, Scan.Parent.Child, Scan.Absolute]
  end

  test "skips dynamic module names and degrades safely on invalid source" do
    source = ~S'''
    defmodule Scan.Static do
    end

    defmodule @dynamic_name do
    end
    '''

    assert ModuleScan.modules(source) == [Scan.Static]
    assert ModuleScan.modules("defmodule Broken do @@@ end") == []
  end
end
