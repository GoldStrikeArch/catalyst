defmodule Catalyst.Prompt.SystemPromptTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.{Model, SystemPrompt}
  alias Catalyst.Prompt.{Registry, Request, Resolution}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_prompts_#{System.unique_integer([:positive, :monotonic])}"
      )

    prompts_dir = Path.join(root, "prompts")
    system_path = Path.join(root, "system_prompt.md")
    File.mkdir_p!(prompts_dir)

    previous =
      Map.new([:prompts, :prompts_dir, :system_prompt_path], fn key ->
        {key, Application.fetch_env(:catalyst, key)}
      end)

    Application.delete_env(:catalyst, :prompts)
    Application.put_env(:catalyst, :prompts_dir, prompts_dir)
    Application.put_env(:catalyst, :system_prompt_path, system_path)

    case Process.whereis(Registry) do
      nil -> start_supervised!(Registry)
      _pid -> clear_runtime()
    end

    on_exit(fn ->
      clear_runtime()
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      File.rm_rf!(root)
    end)

    {:ok, prompts_dir: prompts_dir, system_path: system_path}
  end

  test "system resolution honors layer precedence and reports the winning source", %{
    prompts_dir: prompts_dir,
    system_path: system_path
  } do
    model = model()
    id_path = write!(Path.join(prompts_dir, "model-one.md"), "id file")
    api_path = write!(Path.join(prompts_dir, "test-api.md"), "api file")
    write!(system_path, "global file")

    Application.put_env(:catalyst, :prompts, %{
      system: %{
        "model-one" => "application id",
        "test-api" => "application api",
        default: "application default"
      }
    })

    assert :ok = Registry.register_prompt("test-api", "runtime api", owner: "runtime-owner")

    assert_resolution(
      resolve(:system, model),
      "runtime api",
      [{:extension, "runtime-owner", {:text, :system, "test-api"}}]
    )

    assert :ok = Registry.unregister_owner("runtime-owner")

    assert_resolution(
      resolve(:system, model),
      "application id",
      [{:application, {:prompts, :system, "model-one"}}]
    )

    Application.delete_env(:catalyst, :prompts)
    assert_resolution(resolve(:system, model), "id file", [{:file, id_path}])

    File.rm!(id_path)
    assert_resolution(resolve(:system, model), "api file", [{:file, api_path}])

    File.rm!(api_path)
    assert_resolution(resolve(:system, model), "global file", [{:file, system_path}])

    File.rm!(system_path)
    assert_resolution(resolve(:system, model), SystemPrompt.default(), [:builtin])
  end

  test "exact model id wins over api and default within the runtime layer" do
    assert :ok = Registry.register_prompt(:default, "runtime default", owner: "runtime")
    assert :ok = Registry.register_prompt("test-api", "runtime api", owner: "runtime")
    assert :ok = Registry.register_prompt("model-one", "runtime id", owner: "runtime")

    assert_resolution(
      resolve(:system, model()),
      "runtime id",
      [{:extension, "runtime", {:text, :system, "model-one"}}]
    )

    assert_resolution(
      resolve(:system, nil),
      "runtime default",
      [{:extension, "runtime", {:text, :system, :default}}]
    )
  end

  test "session override wins and append.md contributes ordered provenance", %{
    prompts_dir: prompts_dir
  } do
    append_path = write!(Path.join(prompts_dir, "append.md"), "appended rules")
    Application.put_env(:catalyst, :prompts, :malformed_but_shadowed)

    request = %Request{purpose: :system, model: model(), override: "session prompt"}
    assert {:ok, resolution} = SystemPrompt.resolve(request)

    assert resolution.text == "session prompt\n\nappended rules"
    assert resolution.sources == [{:session, :override}, {:file, append_path}]
    assert resolution.digest == Resolution.digest(resolution.text)
  end

  test "blank selected override is a tagged error" do
    request = %Request{purpose: :system, model: model(), override: "  \n"}

    assert {:error, {:invalid_prompt_override, "  \n"}} = SystemPrompt.resolve(request)
  end

  test "blank files are skipped and a nonblank append is system-only", %{
    prompts_dir: prompts_dir,
    system_path: system_path
  } do
    write!(Path.join(prompts_dir, "model-one.md"), " \n ")
    api_path = write!(Path.join(prompts_dir, "test-api.md"), "api fallback")
    write!(Path.join(prompts_dir, "append.md"), " \n ")
    write!(system_path, "global")

    assert_resolution(resolve(:system, model()), "api fallback", [{:file, api_path}])
  end

  test "compaction uses its own chain and ignores system override and append", %{
    prompts_dir: prompts_dir
  } do
    append_path = write!(Path.join(prompts_dir, "append.md"), "must not append")
    id_path = write!(Path.join([prompts_dir, "compaction", "model-one.md"]), "compact id")
    api_path = write!(Path.join([prompts_dir, "compaction", "test-api.md"]), "compact api")
    generic_path = write!(Path.join(prompts_dir, "compaction.md"), "compact generic")

    request = %Request{purpose: :compaction, model: model(), override: "ignored system override"}

    assert_resolution(SystemPrompt.resolve(request), "compact id", [{:file, id_path}])
    refute elem(SystemPrompt.resolve(request), 1).text =~ File.read!(append_path)

    File.rm!(id_path)
    assert_resolution(SystemPrompt.resolve(request), "compact api", [{:file, api_path}])

    File.rm!(api_path)
    assert_resolution(SystemPrompt.resolve(request), "compact generic", [{:file, generic_path}])

    File.rm!(generic_path)

    assert_resolution(
      SystemPrompt.resolve(request),
      SystemPrompt.compaction_default(),
      [:builtin]
    )
  end

  test "runtime and application compaction prompts precede compaction files", %{
    prompts_dir: prompts_dir
  } do
    write!(Path.join([prompts_dir, "compaction", "model-one.md"]), "file")

    Application.put_env(:catalyst, :prompts, %{
      compaction: %{"model-one" => "application compact"}
    })

    assert_resolution(
      resolve(:compaction, model()),
      "application compact",
      [{:application, {:prompts, :compaction, "model-one"}}]
    )

    assert :ok =
             Registry.register_prompt("test-api", "runtime compact",
               purpose: :compaction,
               owner: "runtime"
             )

    assert_resolution(
      resolve(:compaction, model()),
      "runtime compact",
      [{:extension, "runtime", {:text, :compaction, "test-api"}}]
    )
  end

  test "slug replaces unsafe characters and model files stay beneath prompts_dir", %{
    prompts_dir: prompts_dir
  } do
    unsafe = "../../outside model/with spaces"
    slug = SystemPrompt.slug(unsafe)

    refute String.contains?(slug, "/")
    path = write!(Path.join(prompts_dir, slug <> ".md"), "safe model prompt")
    model = %Model{id: unsafe, api: "test-api"}

    assert Path.dirname(path) == prompts_dir
    assert_resolution(resolve(:system, model), "safe model prompt", [{:file, path}])
  end

  test "final text is repaired as UTF-8 before digesting", %{prompts_dir: prompts_dir} do
    path = write!(Path.join(prompts_dir, "model-one.md"), <<"bad", 255, "text">>)

    assert {:ok, resolution} = resolve(:system, model())
    assert resolution.text == "bad�text"
    assert String.valid?(resolution.text)
    assert resolution.digest == Resolution.digest("bad�text")
    assert resolution.sources == [{:file, path}]
  end

  test "malformed live prompt configuration fails instead of falling through" do
    Application.put_env(:catalyst, :prompts, %{system: %{"" => "bad"}})

    assert {:error, {:invalid_prompt_config, {:invalid_model_key, :system, ""}}} =
             resolve(:system, model())
  end

  test "nil model consults only the default application key" do
    Application.put_env(:catalyst, :prompts, %{
      system: %{"model-one" => "model", default: "default"}
    })

    assert_resolution(
      resolve(:system, nil),
      "default",
      [{:application, {:prompts, :system, :default}}]
    )
  end

  test "get/0 keeps the compatibility global-file-or-built-in contract", %{
    prompts_dir: prompts_dir,
    system_path: system_path
  } do
    Application.put_env(:catalyst, :prompts, %{system: %{default: "application"}})
    assert :ok = Registry.register_prompt(:default, "runtime")
    write!(Path.join(prompts_dir, "append.md"), "append")

    assert SystemPrompt.get() == SystemPrompt.default()

    write!(system_path, "legacy global")
    assert SystemPrompt.get() == "legacy global"
  end

  test "unknown purposes are rejected" do
    assert {:error, {:invalid_prompt_purpose, :other}} =
             SystemPrompt.resolve(%Request{purpose: :other})
  end

  defp model, do: %Model{id: "model-one", api: "test-api"}

  defp resolve(purpose, model) do
    SystemPrompt.resolve(%Request{purpose: purpose, model: model})
  end

  defp assert_resolution({:ok, resolution}, text, sources) do
    assert resolution.text == text
    assert resolution.sources == sources
    assert resolution.digest == Resolution.digest(text)
  end

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp clear_runtime do
    case Process.whereis(Registry) do
      pid when is_pid(pid) ->
        Registry.runtime_entries()
        |> Enum.each(&Registry.unregister(&1.key))

      _not_started ->
        :ok
    end
  end
end
