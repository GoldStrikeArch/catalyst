defmodule Catalyst.Runtime.ImplementationGuaranteeTest do
  use ExUnit.Case, async: true

  alias Catalyst.Extension.Manifest

  alias Catalyst.Runtime.{
    ArtifactId,
    ImplementationGuarantee,
    ImplementationRef,
    ServiceKey
  }

  test "classifies concrete targets without consulting trust labels" do
    artifact = ArtifactId.from_source("defmodule Exact do end")

    assert ImplementationGuarantee.classify(
             ImplementationRef.local(:engine, :physical_engine, artifact)
           ) == :artifact_qualified_local

    assert ImplementationGuarantee.classify(ImplementationRef.external_worker(:policy, :v1)) ==
             :external_worker

    assert ImplementationGuarantee.classify(ImplementationRef.process(:session, :server, :v1)) ==
             :sovereign_local_process

    assert ImplementationGuarantee.classify(ImplementationRef.local(:engine, :engine)) ==
             :same_name_local

    assert ImplementationGuarantee.classify(Catalyst.Agent.Loop) == :same_name_local
  end

  test "classifies managed owners from manifest targets and legacy owners as opaque" do
    manifest =
      Manifest.new!(%{
        id: "external-policy",
        version: "1.0.0",
        trust: :local_trusted,
        services: [
          %{
            key: ServiceKey.new!("agent", "permission_policy"),
            contract: {"catalyst.permission-policy", 1},
            implementation: ImplementationRef.external_worker(:policy, :v1)
          }
        ]
      })

    owners = %{"managed.ex" => [manifest]}

    assert ImplementationGuarantee.owner("managed.ex", owners) == [:external_worker]
    assert ImplementationGuarantee.owner("legacy.ex", owners) == [:raw_legacy_opaque]
  end
end
