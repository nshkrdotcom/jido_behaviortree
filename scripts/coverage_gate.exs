overall_threshold = 85.0
critical_threshold = 85.0

critical_files = [
  "lib/jido_behaviortree/agent.ex",
  "lib/jido_behaviortree/node.ex",
  "lib/jido_behaviortree/tree.ex",
  "lib/jido_behaviortree/skill.ex",
  "lib/jido_behaviortree/nodes/action.ex",
  "lib/jido_behaviortree/strategy/behavior_tree.ex"
]

coverage_json_path = "cover/cov.json"

unless File.exists?(coverage_json_path) do
  Mix.raise("Coverage report not found at #{coverage_json_path}. Run `mix coveralls.json` first.")
end

{:ok, raw_json} = File.read(coverage_json_path)
{:ok, decoded} = Jason.decode(raw_json)
source_files = Map.fetch!(decoded, "source_files")

file_stats =
  Enum.map(source_files, fn %{"name" => name, "coverage" => coverage} ->
    relevant = Enum.count(coverage, &(not is_nil(&1)))
    covered = Enum.count(coverage, &(is_integer(&1) and &1 > 0))
    percent = if relevant == 0, do: 100.0, else: covered / relevant * 100.0
    %{name: name, relevant: relevant, covered: covered, percent: percent}
  end)

total_relevant = Enum.sum(Enum.map(file_stats, & &1.relevant))
total_covered = Enum.sum(Enum.map(file_stats, & &1.covered))
overall_percent = if total_relevant == 0, do: 100.0, else: total_covered / total_relevant * 100.0

missing_critical =
  Enum.filter(critical_files, fn file ->
    Enum.all?(file_stats, &(&1.name != file))
  end)

if missing_critical != [] do
  Mix.raise("Critical coverage files missing from report: #{Enum.join(missing_critical, ", ")}")
end

critical_failures =
  Enum.flat_map(critical_files, fn critical_file ->
    case Enum.find(file_stats, &(&1.name == critical_file)) do
      nil ->
        ["#{critical_file} not found"]

      %{percent: percent} when percent < critical_threshold ->
        ["#{critical_file}: #{Float.round(percent, 1)}% < #{critical_threshold}%"]

      _ ->
        []
    end
  end)

overall_failure? = overall_percent < overall_threshold

IO.puts(
  "Coverage gate results: overall=#{Float.round(overall_percent, 1)}% " <>
    "(threshold #{overall_threshold}%), critical_threshold=#{critical_threshold}%"
)

if overall_failure? or critical_failures != [] do
  messages =
    [
      if(overall_failure?, do: "overall #{Float.round(overall_percent, 1)}% < #{overall_threshold}%", else: nil)
      | critical_failures
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")

  Mix.raise("Coverage gate failed: #{messages}")
end

IO.puts("Coverage gate passed.")
