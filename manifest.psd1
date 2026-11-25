# The files that make up the claude_memory system, shared by install.ps1 and
# tools/export-from-live.ps1 so the two can never disagree about what belongs.
#
# Every file listed under Home and Runner is a TEMPLATE in this repo: machine-specific
# values are replaced by {{TOKENS}} on export and filled back in on install.
# memdb.exe is not listed: install.ps1 compiles it from memdb\src into <ClaudeHome>\bin.
@{
    # Relative to the Claude config folder (~\.claude). Stored in the repo under home\.
    Home = @(
        'CLAUDE.md'
        'claude_memory_schema.sql'
        'session_boot.sh'
        'session_close.sh'
        'archive_transcripts.ps1'
        'claude_scanner.sh'
        'scanner_awk.sh'
        'consolidator\tier1_mechanical.sql'
        'consolidator\judgment_procs.sql'
        'consolidator\behaviours.sql'
        'consolidator\digest.sql'
        'consolidator\confirm.sql'
        'skills\memory\SKILL.md'
        'skills\memory\scripts\mem.ps1'
        'skills\recall\SKILL.md'
        'skills\consolidate-memory-db\SKILL.md'
        'skills\reflect\SKILL.md'
    )

    # Relative to the consolidation runner folder (C:\Tools\consolidator by default).
    # Stored in the repo under consolidator-runner\.
    Runner = @(
        'run-consolidation.ps1'
        'runner-settings.json'
    )

    # Relative to the reflection runner folder (C:\Tools\reflector by default). Stored in the repo
    # under reflector-runner\. Fires the 'reflect' skill headless every 3 hours; the skill's
    # one-pass-per-day guard makes the first slot of each day the one that reflects.
    Reflector = @(
        'run-reflection.ps1'
        'runner-settings.json'
    )

    # Relative to the voice listener folder (C:\Tools\listener by default). Stored in the repo
    # under listener\. SOURCE ONLY: the speech/voice models (~1.9 GB of ONNX/GGML binaries) and the
    # enrolled voiceprints in voices\ (personal biometrics) never enter the repo -- listener\README.md
    # says where each model comes from and how to enroll. listener.json is not exported either (its
    # Prompt carries personal names and project jargon); install.ps1 seeds it once from the
    # hand-written listener\listener.template.json and never overwrites it. install.ps1 renders and
    # builds the listener (-SkipListener to leave it out); models and enrollment stay manual.
    Listener = @(
        'voice-settings.json'
        'worker-settings.json'
        'src\Listener.csproj'
        'src\nuget.config'
        'src\Addressee.cs'
        'src\Brain.cs'
        'src\Embedder.cs'
        'src\Microphone.cs'
        'src\Program.cs'
        'src\PronunciationLexicon.cs'
        'src\Responder.cs'
        'src\Salience.cs'
        'src\SoundTagger.cs'
        'src\SpeakerId.cs'
        'src\Transcriber.cs'
        'src\Worker.cs'
    )

    # Database build order, all run through memdb. 'db:' paths are under db\ in the repo,
    # 'home:' paths under home\. Every file is safe to re-run.
    Database = @(
        'home:claude_memory_schema.sql'
        'db:seed.sql'
        'home:consolidator\tier1_mechanical.sql'
        'home:consolidator\judgment_procs.sql'
        'home:consolidator\behaviours.sql'
        'home:consolidator\digest.sql'
        'home:consolidator\confirm.sql'
    )

    # Seed tables exported from a live database by tools\export-from-live.ps1 into db\seed.sql.
    # Upsert = refresh on re-install; Ignore = keep whatever the target already has.
    Seed = @(
        @{ Table = 'reference_queries';        Key = 'name';    Columns = @('name', 'description', 'sql_template', 'category'); Mode = 'Upsert' }
        @{ Table = 'consolidation_config';     Key = 'cfg_key'; Columns = @('cfg_key', 'cfg_value', 'note');                   Mode = 'Ignore' }
        @{ Table = 'behaviour_evidence_kinds'; Key = 'kind';    Columns = @('kind', 'anchor_weight', 'description');           Mode = 'Ignore' }
    )

    # What a complete install contains, checked at the end of install.ps1.
    Expect = @{ Tables = 32; FtsIndexes = 9; Views = 14; Procedures = 21 }
}
