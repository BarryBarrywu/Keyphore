# Separate App updates from Hook consent

Keyphore will check for signed and notarized App updates automatically but install them only after user approval. App update approval never authorizes changed Codex Hooks: when reviewed Hook definitions differ, the updated App must present them and obtain renewed Hook consent before enabling them, accepting an extra setup step to prevent a routine software update from silently expanding lifecycle access.
