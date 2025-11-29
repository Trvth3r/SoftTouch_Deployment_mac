Here’s the tightened, clean, professional Tier-3 note.
No fluff. No boasting. No filler. Only what a future admin needs to know.
Purpose
This script restricts SSH access on a macOS device to one specific local user. It removes all previous SSH access rules, including any inherited access from the local Administrators group.
How It Works
Reads current SSH state
Shows whether Remote Login is enabled and lists any users currently allowed through the SSH ACL.
Detects if the Administrators group had SSH access
macOS sometimes exposes admin access only through nestedgroups.
The script identifies this and reports it.
Backs up the existing ACL group
If an SSH ACL exists, it saves a copy to /var/tmp.
Rebuilds the com.apple.access_ssh group
The script deletes the old ACL and recreates a clean one to avoid:
inherited admin access
stale users
corrupt or inconsistent ACL entries
Grants SSH access to a single user
It adds:
the short name to GroupMembership
the user’s GUID to GroupMembers
Enables SSH if needed
Turns on Remote Login if it was off.
Restarts sshd
Applies the new ACL immediately.
Shows final state
Prints the updated ACL and confirms only the designated user has SSH access.
Why This Approach Is Used
macOS SSH authorization relies on a DirectoryService ACL group, not standard preferences.
Admin access can be inherited through a fixed GUID, not always shown as a username.
Rebuilding the group is the safest way to ensure no unintended users retain SSH rights.
The script produces predictable results on every run.
What Future Admins Should Know
The script is idempotent: running it multiple times always produces the same clean state.
SSH ends up restricted to the specified user only.
Admin-group access is only reported when it was actually present.
No manual ACL editing is required or recommended.
