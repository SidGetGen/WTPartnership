/**
 * OpportunityEmailRouter
 *
 * Invocable recipient resolver called by all Opportunity notification flows.
 * Returns a comma-separated email address string AND a User ID collection
 * by querying the appropriate Public Group based on the Opportunity's access
 * classification.
 *
 * Routing matrix:
 *   Normal  (both flags false)        → email = owner only;  IDs = [ownerId]
 *   Restricted only (Restricted=true) → email + IDs = SalesTeam_Restricted members
 *   Top Secret only (TopSecret=true)  → email + IDs = SalesTeam_TopSecret members
 *   Both flags true                   → email + IDs = SalesTeam_Restricted ∪ SalesTeam_TopSecret
 *
 * SalesTeam_All is used only for sharing rules and is never queried here.
 *
 * Fallback: if a group has no active members, email and recipientIds fall back
 * to the owner so notifications are never silently dropped.
 *
 * Governor-limit budget per transaction (worst case, 200 Opps):
 *   SOQLs : 3  (Group, GroupMember, User) — all bulk-queried once outside loops
 *   DMLs  : 0
 */
public without sharing class OpportunityEmailRouter {
  private static final String GROUP_RESTRICTED = 'SalesTeam_Restricted';
  private static final String GROUP_TOP_SECRET = 'SalesTeam_TopSecret';

  // ─── Invocable Request DTO ───────────────────────────────────────────────

  public class Request {
    @InvocableVariable(label='Is Restricted' required=true)
    public Boolean isRestricted;

    @InvocableVariable(label='Is Top Secret' required=true)
    public Boolean isTopSecret;

    @InvocableVariable(label='Owner Email' required=true)
    public String ownerEmail;

    @InvocableVariable(label='Owner Id' required=true)
    public String ownerId;
  }

  // ─── Invocable Result DTO ────────────────────────────────────────────────

  public class Result {
    @InvocableVariable(label='Email Addresses')
    public String emailAddresses;

    @InvocableVariable(label='Recipient IDs')
    public List<String> recipientIds;
  }

  // ─── Test seam ───────────────────────────────────────────────────────────
  // Map of Group DeveloperName → List<User> (with Id and Email populated)
  @TestVisible
  private static Map<String, List<User>> mockGroupMembership;

  // ─── Invocable Entry Point ───────────────────────────────────────────────

  @InvocableMethod(
    label='Resolve Opportunity Notification Recipients'
    description='Returns recipientIds (for in-app notification) and emailAddresses (for emailSimple) based on the Opportunity access classification. Normal opps → owner. Restricted/Top Secret → matching Public Group members.'
    category='Opportunity'
  )
  public static List<Result> resolve(List<Request> requests) {
    // ── 1. Determine which groups are needed across the whole batch ────────
    Boolean needRestricted = false;
    Boolean needTopSecret = false;

    for (Request req : requests) {
      if (req.isRestricted == true)
        needRestricted = true;
      if (req.isTopSecret == true)
        needTopSecret = true;
    }

    // ── 2. Bulk-query only the groups actually needed (0–2 groups) ────────
    Set<String> neededDevNames = new Set<String>();
    if (needRestricted)
      neededDevNames.add(GROUP_RESTRICTED);
    if (needTopSecret)
      neededDevNames.add(GROUP_TOP_SECRET);

    Map<String, List<User>> membersByGroup = neededDevNames.isEmpty()
      ? new Map<String, List<User>>()
      : buildGroupMembershipMap(neededDevNames);

    // ── 3. Build results per request ──────────────────────────────────────
    List<Result> results = new List<Result>();

    for (Request req : requests) {
      Result res = new Result();
      Boolean isR = req.isRestricted == true;
      Boolean isT = req.isTopSecret == true;

      if (!isR && !isT) {
        // Normal: owner only for both email and in-app notification
        res.emailAddresses = req.ownerEmail;
        res.recipientIds = new List<String>{ req.ownerId };
      } else {
        List<User> members;
        if (isR && isT) {
          // Both: union Restricted + TopSecret (deduplicated by Id)
          Map<Id, User> merged = new Map<Id, User>();
          for (User u : membersByGroup.get(GROUP_RESTRICTED))
            merged.put(u.Id, u);
          for (User u : membersByGroup.get(GROUP_TOP_SECRET))
            merged.put(u.Id, u);
          members = merged.values();
        } else if (isR) {
          members = membersByGroup.get(GROUP_RESTRICTED);
        } else {
          members = membersByGroup.get(GROUP_TOP_SECRET);
        }

        if (members == null || members.isEmpty()) {
          // Fallback to owner if the group has no active members
          res.emailAddresses = req.ownerEmail;
          res.recipientIds = new List<String>{ req.ownerId };
        } else {
          res.emailAddresses = buildEmailString(members, req.ownerEmail);
          res.recipientIds = new List<String>();
          for (User u : members) {
            res.recipientIds.add(u.Id);
          }
        }
      }

      results.add(res);
    }

    return results;
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  private static Map<String, List<User>> buildGroupMembershipMap(
    Set<String> devNames
  ) {
    Map<String, List<User>> result = new Map<String, List<User>>();
    for (String name : devNames) {
      result.put(name, new List<User>());
    }

    if (mockGroupMembership != null) {
      for (String name : devNames) {
        if (mockGroupMembership.containsKey(name)) {
          result.put(name, mockGroupMembership.get(name));
        }
      }
      return result;
    }

    // ── SOQL 1 — Group Ids ────────────────────────────────────────────────
    Map<Id, String> devNameByGroupId = new Map<Id, String>();
    for (Group g : [
      SELECT Id, DeveloperName
      FROM Group
      WHERE DeveloperName IN :devNames AND Type = 'Regular'
    ]) {
      devNameByGroupId.put(g.Id, g.DeveloperName);
    }
    if (devNameByGroupId.isEmpty()) {
      return result;
    }

    // ── SOQL 2 — GroupMember rows (User IDs only — skip nested groups) ────
    String userKeyPrefix = User.sObjectType.getDescribe().getKeyPrefix();
    Map<String, Set<Id>> userIdsByGroup = new Map<String, Set<Id>>();
    for (String name : devNames) {
      userIdsByGroup.put(name, new Set<Id>());
    }
    for (GroupMember gm : [
      SELECT GroupId, UserOrGroupId
      FROM GroupMember
      WHERE GroupId IN :devNameByGroupId.keySet()
    ]) {
      if (String.valueOf(gm.UserOrGroupId).startsWith(userKeyPrefix)) {
        String devName = devNameByGroupId.get(gm.GroupId);
        userIdsByGroup.get(devName).add(gm.UserOrGroupId);
      }
    }

    // Collect all unique user IDs across groups
    Set<Id> allUserIds = new Set<Id>();
    for (Set<Id> ids : userIdsByGroup.values()) {
      allUserIds.addAll(ids);
    }
    if (allUserIds.isEmpty()) {
      return result;
    }

    // ── SOQL 3 — User details ─────────────────────────────────────────────
    Map<Id, User> userById = new Map<Id, User>(
      [
        SELECT Id, Email
        FROM User
        WHERE Id IN :allUserIds AND IsActive = TRUE
      ]
    );

    for (String devName : userIdsByGroup.keySet()) {
      List<User> groupUsers = new List<User>();
      for (Id uid : userIdsByGroup.get(devName)) {
        if (userById.containsKey(uid)) {
          groupUsers.add(userById.get(uid));
        }
      }
      result.put(devName, groupUsers);
    }

    return result;
  }

  private static String buildEmailString(List<User> members, String fallback) {
    if (members == null || members.isEmpty()) {
      return fallback;
    }
    List<String> emails = new List<String>();
    for (User u : members) {
      if (String.isNotBlank(u.Email)) {
        emails.add(u.Email);
      }
    }
    return emails.isEmpty() ? fallback : String.join(emails, ',');
  }
}
