defmodule Catalyst.Runtime.Transport do
  @moduledoc """
  Invocation boundary for runtime service targets.

  Local targets are ordinary modules. Process targets implement a small OTP
  protocol by handling `{:catalyst_runtime, protocol, callback, arguments}`
  calls. This permits sovereign in-node subsystems without exposing their
  internal process topology to service consumers. It is not an isolation
  boundary; external workers require a separate transport.
  """

  alias Catalyst.Runtime.{Handle, ImplementationRef}

  @default_process_timeout 30_000

  @doc "Invoke one callback through a pinned handle's declared transport."
  @spec invoke(Handle.t(), atom(), [term()]) :: term()
  def invoke(%Handle{} = handle, callback, args) when is_atom(callback) and is_list(args) do
    case handle.resolution.claim.implementation do
      %ImplementationRef{transport: :local} ->
        apply(handle.implementation, callback, args)

      %ImplementationRef{
        transport: :process,
        target: %{server: server, protocol: protocol}
      } ->
        GenServer.call(
          server,
          {:catalyst_runtime, protocol, callback, args},
          process_timeout()
        )

      implementation ->
        apply(ImplementationRef.target(implementation), callback, args)
    end
  end

  defp process_timeout do
    case Application.get_env(
           :catalyst,
           :runtime_process_transport_timeout,
           @default_process_timeout
         ) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_process_timeout
    end
  end
end
