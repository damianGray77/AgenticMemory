# The files that make up the claude_memory system, shared by install.ps1 and
# tools/export-from-live.ps1 so the two can never disagree about what belongs.
#
# Every file listed under Home and Runner is a TEMPLATE in this repo: machine-specific
# values are replaced by {{TOKENS}} on export and filled back in on install.
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
    )

    # Relative to the consolidation runner folder (C:\Tools\consolidator by default).
    # Stored in the repo under consolidator-runner\.
    Runner = @(
        'run-consolidation.ps1'
        'runner-settings.json'
    )

    # Database build order. 'db:' paths are under db\ in the repo, 'home:' paths under home\.
    # NoDb = run without selecting the database (the file selects or creates it itself).
    Database = @(
        @{ File = 'db:server-settings.sql';                 NoDb = $true  }
        @{ File = 'home:claude_memory_schema.sql';           NoDb = $true  }
        @{ File = 'db:seed.sql';                             NoDb = $false }
        @{ File = 'home:consolidator\tier1_mechanical.sql';  NoDb = $false }
        @{ File = 'home:consolidator\judgment_procs.sql';    NoDb = $false }
        @{ File = 'home:consolidator\behaviours.sql';        NoDb = $false }
        @{ File = 'home:consolidator\digest.sql';            NoDb = $false }
        @{ File = 'home:consolidator\confirm.sql';           NoDb = $false }
        @{ File = 'db:event.sql';                            NoDb = $false }
    )

    # Seed tables exported from the live database by tools\export-from-live.ps1 into db\seed.sql.
    # Upsert = refresh on re-install; Ignore = keep whatever the target already has.
    Seed = @(
        @{ Table = 'reference_queries';        Key = 'name';    Columns = @('name', 'description', 'sql_template', 'category'); Mode = 'Upsert' }
        @{ Table = 'consolidation_config';     Key = 'cfg_key'; Columns = @('cfg_key', 'cfg_value', 'note');                   Mode = 'Ignore' }
        @{ Table = 'behaviour_evidence_kinds'; Key = 'kind';    Columns = @('kind', 'anchor_weight', 'description');           Mode = 'Ignore' }
    )

    # What a complete install contains, checked at the end of install.ps1.
    Expect = @{ Tables = 25; Views = 14; Procedures = 21; Events = 1 }
}
