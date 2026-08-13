defmodule Catalyst.Workflow.Attempt.Session do
  @moduledoc false

  @behaviour Catalyst.Workflow.Attempt.SessionAdapter

  alias Catalyst.Session.{Manager, Server}

  @impl true
  def start_fresh(opts), do: Manager.start_unique_session(opts)

  @impl true
  def resume(opts), do: Manager.start_session(opts)

  @impl true
  def subscribe(session_id),
    do: Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(session_id))

  @impl true
  def unsubscribe(session_id),
    do: Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(session_id))

  @impl true
  def prompt(pid, prompt), do: Server.prompt(pid, prompt)

  @impl true
  def abort(pid), do: Server.abort(pid)

  @impl true
  def stop(session_id), do: Manager.stop(session_id)
end
