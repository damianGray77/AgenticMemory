using System.Text;
using System.Text.RegularExpressions;

/// <summary>
/// Pre-TTS pronunciation step. Every word headed for Kokoro is looked up in the stock lexicons
/// (plus our own custom one); a word found nowhere gets a best-guess pronunciation appended to
/// lexicon-custom.txt automatically -- no approval step. sherpa-onnx reads its lexicons once at
/// startup, so a newly added word is spoken with the guess from the next listener restart on;
/// edit the line in lexicon-custom.txt to correct a guess (it is never overwritten).
/// </summary>
sealed class PronunciationLexicon
{
    public const string CustomFileName = "lexicon-custom.txt";

    static readonly Regex WordRx = new(@"[A-Za-z][A-Za-z']*", RegexOptions.Compiled);

    readonly HashSet<string> _known = new(StringComparer.OrdinalIgnoreCase);
    readonly string _customPath;
    readonly Action<string>? _log;
    readonly object _gate = new();

    public PronunciationLexicon(string kokoroDir, Action<string>? log)
    {
        _log = log;
        _customPath = Path.Combine(kokoroDir, CustomFileName);
        foreach (var f in new[] { "lexicon-us-en.txt", "lexicon-gb-en.txt", CustomFileName })
        {
            var path = Path.Combine(kokoroDir, f);
            if (!File.Exists(path)) continue;
            foreach (var line in File.ReadLines(path))
            {
                var sp = line.IndexOf(' ');
                if (sp > 0) _known.Add(line[..sp]);
            }
        }
    }

    /// <summary>Look up each word in the text; add any unknown ones to the custom lexicon.</summary>
    public void EnsureWords(string text)
    {
        try
        {
            List<string>? fresh = null;
            lock (_gate)
            {
                foreach (Match m in WordRx.Matches(text))
                {
                    var raw = m.Value.Trim('\'');
                    if (raw.Length == 0 || IsKnown(raw)) continue;
                    var key = raw.ToLowerInvariant();
                    var phonemes = Guess(raw);
                    if (phonemes.Length == 0) continue;
                    _known.Add(key);
                    (fresh ??= new()).Add($"{key} {phonemes}");
                }
                if (fresh != null) File.AppendAllLines(_customPath, fresh, new UTF8Encoding(false));
            }
            if (fresh != null) _log?.Invoke($"Lexicon: added {fresh.Count} unknown word(s): {string.Join("; ", fresh)}");
        }
        catch (Exception ex) { _log?.Invoke($"Lexicon update failed ({ex.Message}); speaking as-is"); }
    }

    bool IsKnown(string word)
    {
        if (_known.Contains(word)) return true;
        // possessives and plain plurals of a known word are handled by the phonemizer
        if (word.EndsWith("'s", StringComparison.OrdinalIgnoreCase) && _known.Contains(word[..^2])) return true;
        if (word.Contains('\'')) return true;   // other contractions: leave to the stock rules
        return false;
    }

    // ---- best-guess grapheme-to-phoneme (Kokoro/misaki symbol set, space separated) ----

    static readonly Dictionary<char, string> LetterNames = new()
    {
        ['a'] = "ˈ A", ['b'] = "b ˈ i", ['c'] = "s ˈ i", ['d'] = "d ˈ i", ['e'] = "ˈ i", ['f'] = "ˈ ɛ f",
        ['g'] = "ʤ ˈ i", ['h'] = "ˈ A ʧ", ['i'] = "ˈ I", ['j'] = "ʤ ˈ A", ['k'] = "k ˈ A", ['l'] = "ˈ ɛ l",
        ['m'] = "ˈ ɛ m", ['n'] = "ˈ ɛ n", ['o'] = "ˈ O", ['p'] = "p ˈ i", ['q'] = "k j ˈ u", ['r'] = "ˈ ɑ ɹ",
        ['s'] = "ˈ ɛ s", ['t'] = "t ˈ i", ['u'] = "j ˈ u", ['v'] = "v ˈ i", ['w'] = "d ˈ ʌ b ə l j ˌ u",
        ['x'] = "ˈ ɛ k s", ['y'] = "w ˈ I", ['z'] = "z ˈ i",
    };

    // longest match first; "V" entries are vowels and take the stress mark on the first one
    static readonly (string Graph, string Phones, bool Vowel)[] Rules =
    {
        ("tch", "ʧ", false), ("sch", "s k", false), ("igh", "I", true), ("ough", "O", true),
        ("th", "θ", false), ("sh", "ʃ", false), ("ch", "ʧ", false), ("ph", "f", false), ("wh", "w", false),
        ("ck", "k", false), ("ng", "ŋ", false), ("nk", "ŋ k", false), ("qu", "k w", false), ("gh", "", false),
        ("kn", "n", false), ("wr", "ɹ", false), ("dg", "ʤ", false),
        ("ee", "i", true), ("ea", "i", true), ("oo", "u", true), ("ai", "A", true), ("ay", "A", true),
        ("oa", "O", true), ("ow", "W", true), ("ou", "W", true), ("oi", "ɔ ɪ", true), ("oy", "ɔ ɪ", true),
        ("au", "ɔ", true), ("aw", "ɔ", true), ("ie", "i", true), ("ey", "i", true), ("ue", "u", true),
        ("ar", "ɑ ɹ", true), ("or", "ɔ ɹ", true), ("er", "ɚ", true), ("ir", "ɜ ɹ", true), ("ur", "ɜ ɹ", true),
        ("a", "æ", true), ("e", "ɛ", true), ("i", "ɪ", true), ("o", "ɑ", true), ("u", "ʌ", true), ("y", "i", true),
        ("b", "b", false), ("c", "k", false), ("d", "d", false), ("f", "f", false), ("g", "ɡ", false),
        ("h", "h", false), ("j", "ʤ", false), ("k", "k", false), ("l", "l", false), ("m", "m", false),
        ("n", "n", false), ("p", "p", false), ("q", "k", false), ("r", "ɹ", false), ("s", "s", false),
        ("t", "t", false), ("v", "v", false), ("w", "w", false), ("x", "k s", false), ("z", "z", false),
    };

    static string Guess(string word)
    {
        var w = word.ToLowerInvariant();
        var letters = w.Where(char.IsLetter).ToArray();
        if (letters.Length == 0) return "";
        bool allCaps = word.All(c => !char.IsLetter(c) || char.IsUpper(c));
        bool hasVowel = letters.Any(c => "aeiouy".Contains(c));
        // acronyms (SVN, JSON-ish tickers) and vowel-less strings are spelled out letter by letter
        if ((allCaps && letters.Length is >= 2 and <= 5) || !hasVowel)
            return string.Join(" ", letters.Where(LetterNames.ContainsKey).Select(c => LetterNames[c]));

        var parts = new List<string>();
        var stressed = false;
        for (int i = 0; i < w.Length;)
        {
            // magic-e: a vowel + consonant + final 'e' lengthens ("name", "code")
            if (i == w.Length - 1 && w[i] == 'e' && parts.Count > 1) break;
            var rule = Rules.FirstOrDefault(r => string.CompareOrdinal(w, i, r.Graph, 0, r.Graph.Length) == 0);
            if (rule.Graph == null) { i++; continue; }
            var phones = rule.Phones;
            if (rule.Vowel && phones.Length > 0 && !stressed)
            {
                phones = "ˈ " + LongenIfMagicE(w, i, rule.Graph, phones);
                stressed = true;
            }
            if (phones.Length > 0) parts.Add(phones);
            i += rule.Graph.Length;
        }
        return string.Join(" ", parts);
    }

    static string LongenIfMagicE(string w, int i, string graph, string phones)
    {
        if (graph.Length != 1 || w.Length < i + 3 || w[^1] != 'e') return phones;
        if (i + 2 != w.Length - 1 && i + 3 != w.Length - 1) return phones;   // V C e  (or V CC e is short)
        if (i + 3 == w.Length - 1) return phones;
        if ("aeiouy".Contains(w[i + 1])) return phones;
        return graph switch { "a" => "A", "i" => "I", "o" => "O", "u" => "u", _ => phones };
    }
}
