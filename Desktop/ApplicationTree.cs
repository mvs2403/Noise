namespace Noise;

internal static class ApplicationTree
{
    // Audio may belong to a differently named helper (Teams/WebView2, for example).
    // Choose the outermost selected ancestor, so nested selections never double-capture.
    public static int SelectedRoot(int pid, IReadOnlyDictionary<int, int> parents,
        Func<int, string?> executable, HashSet<string> selected)
    {
        var seen = new HashSet<int>(); int root = 0;
        while (pid > 0 && seen.Add(pid))
        {
            if (executable(pid) is {} path && selected.Contains(path)) root = pid;
            if (!parents.TryGetValue(pid, out pid)) break;
        }
        return root;
    }
}
