defmodule Catalyst.FlexCase do
  @moduledoc """
  Serial ExUnit case template for tests that mutate Catalyst's VM-global runtime seams.

  Cleanup registration order is deliberate: isolated-environment restoration is
  registered first (runs last), then the baseline assertion, then scenario-owned
  cleanup callbacks registered by individual helpers.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Catalyst.Flex.Harness
      alias Catalyst.Flex.{Baseline, Fixtures}
    end
  end

  setup context do
    setup_flex(context)
  end

  @doc false
  @spec setup_flex(map()) :: {:ok, map()}
  def setup_flex(context) do
    home = Catalyst.Flex.Harness.isolated_home!()
    baseline = Catalyst.Flex.Baseline.capture()
    exempt = List.wrap(Map.get(context, :flex_exempt, []))

    ExUnit.Callbacks.on_exit(fn -> Catalyst.Flex.Baseline.assert_clean!(baseline, exempt) end)

    {:ok,
     context
     |> Map.put(:flex_home, home)
     |> Map.put(:flex_baseline, baseline)}
  end
end
