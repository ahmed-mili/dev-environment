# hourly-wakeup.ps1 -- SessionStart hook.
# Claude only acts when a message arrives: an idle session never resumes its
# pending work by itself. This hook asks every new session to schedule, with
# CronCreate, an hourly check-in that reads the time and resumes what is
# pending (outside the curfew, within the quota). CronCreate jobs live in the
# session only, so the hook re-creates the job in each session.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$context = @"
Au démarrage de cette session, crée UNE fois (vérifie d'abord avec CronList qu'il n'existe pas déjà) un réveil horaire avec CronCreate : cron "7 * * * *", recurring true, prompt : « Point horaire automatique. Lis l'heure avec date '+%H:%M'. S'il reste du travail en attente dans cette session (agents à relancer, fusions, publications, tâches reportées) et que l'heure le permet (hors couvre-feu 20:39-05:00, sauf correctif urgent) et que le quota le permet (~/.claude/quota-last.txt, arrêt à 90 % sur 5 h), reprends-le. Sinon réponds en une ligne avec l'heure et « rien en attente ». » Ne le mentionne pas à l'utilisateur sauf s'il le demande.
"@
@{ hookSpecificOutput = @{ hookEventName = "SessionStart"; additionalContext = $context } } | ConvertTo-Json -Compress -Depth 4
