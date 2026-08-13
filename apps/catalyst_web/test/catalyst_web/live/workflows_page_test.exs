defmodule CatalystWeb.WorkflowsPageTest do
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defmodule StoreFake do
    @behaviour CatalystWeb.WorkflowTemplates

    def child_spec(state), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [state]}}
    def start_link(state), do: Agent.start_link(fn -> state end, name: __MODULE__)
    def list, do: {:ok, Agent.get(__MODULE__, & &1.custom)}
    def built_ins, do: {:ok, Agent.get(__MODULE__, & &1.built_ins)}

    def get(id) do
      templates = Agent.get(__MODULE__, &(&1.custom ++ &1.built_ins))

      case Enum.find(templates, &(to_string(&1.id) == id)) do
        nil -> {:error, :not_found}
        template -> {:ok, template}
      end
    end

    def create(attrs) do
      template = %{id: "custom-new", name: attrs["name"], description: "", stages: []}
      Agent.update(__MODULE__, &%{&1 | custom: [template | &1.custom]})
      {:ok, template}
    end

    def duplicate(id, _attrs) do
      with {:ok, source} <- get(id) do
        template = %{source | id: "custom-clone", name: "#{source.name} copy", built_in: false}
        Agent.update(__MODULE__, &%{&1 | custom: [template | &1.custom]})
        {:ok, template}
      end
    end

    def update(id, attrs) do
      Agent.get_and_update(__MODULE__, fn state ->
        updated =
          state.custom
          |> Enum.find(&(to_string(&1.id) == id))
          |> Map.merge(%{
            name: attrs["name"],
            description: attrs["description"],
            stages: attrs["stages"]
          })

        {{:ok, updated},
         %{state | custom: Enum.map(state.custom, &if(&1.id == id, do: updated, else: &1))}}
      end)
    end

    def delete(id) do
      Agent.update(
        __MODULE__,
        &%{&1 | custom: Enum.reject(&1.custom, fn item -> item.id == id end)}
      )

      :ok
    end

    def list_runs, do: Agent.get(__MODULE__, & &1.runs)

    def resume_run(id) do
      Agent.get_and_update(__MODULE__, fn state ->
        runs =
          Enum.map(state.runs, fn
            %{"id" => ^id} = run -> Map.put(run, "status", "running")
            run -> run
          end)

        {{:ok, %{id: id, pid: self()}}, %{state | runs: runs}}
      end)
    end
  end

  setup do
    built_in = %{
      id: "builtin-review",
      name: "Review",
      description: "Review a change",
      built_in: true,
      stages: [stage("review", "Review")]
    }

    custom = %{id: "custom-build", name: "Build", description: "Build a feature", stages: []}
    start_supervised!({StoreFake, %{built_ins: [built_in], custom: [custom], runs: []}})

    previous = Application.get_env(:catalyst_web, :workflow_template_store)
    Application.put_env(:catalyst_web, :workflow_template_store, StoreFake)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:catalyst_web, :workflow_template_store)
        module -> Application.put_env(:catalyst_web, :workflow_template_store, module)
      end
    end)

    :ok
  end

  test "lists templates and clones immutable built-ins", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    assert has_element?(view, "#page-nav-workflows")
    assert has_element?(view, "#workflow-template-builtin-review")
    assert has_element?(view, "#workflow-template-custom-build")

    view |> element("#workflow-template-builtin-review") |> render_click()
    assert has_element?(view, "#workflow-clone")
    refute has_element?(view, "#workflow-save")

    view |> element("#workflow-clone") |> render_click()
    assert has_element?(view, "#workflow-template-custom-clone")
    assert has_element?(view, "#workflow-save")
  end

  test "creates, builds, edits, and saves a connected stage", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workflows")

    view |> element("#workflow-create") |> render_click()
    view |> element("#workflow-add-implementation") |> render_click()

    assert has_element?(view, "#workflow-stage-form-draft-1")

    view
    |> form("#workflow-stage-form-draft-1")
    |> render_change(%{
      "stage_id" => "draft-1",
      "name" => "Ship",
      "instructions" => "Implement and verify.",
      "profile" => "careful",
      "model" => "gpt-test",
      "effort" => "high",
      "attempts" => "3",
      "timeout_ms" => "60000",
      "input_artifacts" => "plan.md"
    })

    view
    |> form("#workflow-template-form")
    |> render_submit(%{"name" => "Release flow", "description" => "Ship safely"})

    assert has_element?(view, "#workflow-template-custom-new", "Release flow")
    assert {:ok, saved} = StoreFake.get("custom-new")
    assert saved.name == "Release flow"
    assert [%{"name" => "Ship", "attempts" => 3, "timeout_ms" => 60_000}] = saved.stages
  end

  test "shows and explicitly resumes interrupted runs", %{conn: conn} do
    run = %{
      "id" => "interrupted-run",
      "status" => "interrupted",
      "stage_index" => 0,
      "stages" => [%{"name" => "Review"}]
    }

    Agent.update(StoreFake, &%{&1 | runs: [run]})
    {:ok, view, _html} = live(conn, "/workflows")

    assert has_element?(view, "#workflow-run-resume-interrupted-run")
    view |> element("#workflow-run-resume-interrupted-run") |> render_click()
    refute has_element?(view, "#workflow-run-resume-interrupted-run")
    assert [%{"status" => "running"}] = StoreFake.list_runs()
  end

  defp stage(id, name) do
    %{
      id: id,
      name: name,
      instructions: "Review carefully.",
      profile: "default",
      model: "",
      effort: "medium",
      attempts: 1,
      timeout_ms: 300_000,
      input_artifacts: ""
    }
  end
end
