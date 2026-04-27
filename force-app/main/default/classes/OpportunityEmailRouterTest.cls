/**
 * OpportunityEmailRouterTest
 *
 * Test coverage for OpportunityEmailRouter.
 *
 * The @TestVisible mockGroupMembership seam is used to inject synthetic group
 * member data so tests do not depend on Public Group records existing in the org.
 */
@IsTest
private class OpportunityEmailRouterTest {
  // ─── Shared test data ────────────────────────────────────────────────────

  @TestSetup
  static void makeData() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    insert new List<User>{
      buildUser('restricted.member@routertest.example.com', 'resmem', p.Id),
      buildUser('topsecret.member@routertest.example.com', 'tsmem', p.Id),
      buildUser('shared.member@routertest.example.com', 'shmem', p.Id),
      buildUser('opportunity.owner@routertest.example.com', 'owner', p.Id)
    };
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  private static User buildUser(String username, String alias, Id profileId) {
    return new User(
      LastName = alias,
      Email = username,
      Username = username,
      Alias = alias,
      TimeZoneSidKey = 'Australia/Sydney',
      LocaleSidKey = 'en_AU',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = profileId
    );
  }

  private static User getUser(String username) {
    return [SELECT Id, Email FROM User WHERE Username = :username LIMIT 1];
  }

  private static OpportunityEmailRouter.Request buildRequest(
    Boolean restricted,
    Boolean topSecret,
    String ownerEmail,
    String ownerId
  ) {
    OpportunityEmailRouter.Request r = new OpportunityEmailRouter.Request();
    r.isRestricted = restricted;
    r.isTopSecret = topSecret;
    r.ownerEmail = ownerEmail;
    r.ownerId = ownerId;
    return r;
  }

  private static Set<String> splitEmails(String emailStr) {
    Set<String> result = new Set<String>();
    if (String.isNotBlank(emailStr)) {
      result.addAll(emailStr.split(','));
    }
    return result;
  }

  // ─── Test: Normal opp → owner only for both outputs ──────────────────────

  @IsTest
  static void normalOpp_ownerOnlyForBothOutputs() {
    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>();
    User owner = getUser('opportunity.owner@routertest.example.com');

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{
        buildRequest(false, false, owner.Email, owner.Id)
      }
    );
    Test.stopTest();

    Assert.areEqual(
      owner.Email,
      results[0].emailAddresses,
      'Normal opp email must be owner email'
    );
    Assert.areEqual(
      1,
      results[0].recipientIds.size(),
      'Normal opp must have exactly 1 recipient ID'
    );
    Assert.areEqual(
      String.valueOf(owner.Id),
      results[0].recipientIds[0],
      'Recipient ID must be owner ID'
    );
  }

  // ─── Test: Restricted opp → SalesTeam_Restricted members ────────────────

  @IsTest
  static void restrictedOpp_restrictedGroupMembers() {
    User member = getUser('restricted.member@routertest.example.com');
    User owner = getUser('opportunity.owner@routertest.example.com');

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_Restricted' => new List<User>{ member }
    };

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{
        buildRequest(true, false, owner.Email, owner.Id)
      }
    );
    Test.stopTest();

    Assert.areEqual(
      member.Email,
      results[0].emailAddresses,
      'Restricted opp email must be the group member email'
    );
    Assert.areEqual(
      1,
      results[0].recipientIds.size(),
      'Restricted opp must have 1 recipient ID'
    );
    Assert.areEqual(String.valueOf(member.Id), results[0].recipientIds[0]);
  }

  // ─── Test: Top Secret opp → SalesTeam_TopSecret members ─────────────────

  @IsTest
  static void topSecretOpp_topSecretGroupMembers() {
    User member = getUser('topsecret.member@routertest.example.com');
    User owner = getUser('opportunity.owner@routertest.example.com');

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_TopSecret' => new List<User>{ member }
    };

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{
        buildRequest(false, true, owner.Email, owner.Id)
      }
    );
    Test.stopTest();

    Assert.areEqual(member.Email, results[0].emailAddresses);
    Assert.areEqual(1, results[0].recipientIds.size());
    Assert.areEqual(String.valueOf(member.Id), results[0].recipientIds[0]);
  }

  // ─── Test: Both flags → union of both groups ──────────────────────────────

  @IsTest
  static void bothFlags_unionOfBothGroups() {
    User resMember = getUser('restricted.member@routertest.example.com');
    User tsMember = getUser('topsecret.member@routertest.example.com');
    User owner = getUser('opportunity.owner@routertest.example.com');

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_Restricted' => new List<User>{ resMember },
      'SalesTeam_TopSecret' => new List<User>{ tsMember }
    };

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{
        buildRequest(true, true, owner.Email, owner.Id)
      }
    );
    Test.stopTest();

    Set<String> emails = splitEmails(results[0].emailAddresses);
    Assert.isTrue(
      emails.contains(resMember.Email),
      'Restricted member email must be included'
    );
    Assert.isTrue(
      emails.contains(tsMember.Email),
      'Top Secret member email must be included'
    );
    Assert.areEqual(
      2,
      results[0].recipientIds.size(),
      'Both groups should contribute 1 ID each'
    );
  }

  // ─── Test: Both flags with shared member → deduplicated ──────────────────

  @IsTest
  static void bothFlags_sharedMemberDeduplicatedOnce() {
    User shared = getUser('shared.member@routertest.example.com');
    User owner = getUser('opportunity.owner@routertest.example.com');

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_Restricted' => new List<User>{ shared },
      'SalesTeam_TopSecret' => new List<User>{ shared }
    };

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{
        buildRequest(true, true, owner.Email, owner.Id)
      }
    );
    Test.stopTest();

    Assert.areEqual(
      1,
      results[0].recipientIds.size(),
      'Shared member should appear only once in recipientIds'
    );
    Set<String> emails = splitEmails(results[0].emailAddresses);
    Assert.areEqual(
      1,
      emails.size(),
      'Shared member email should appear only once'
    );
  }

  // ─── Test: Empty group → fallback to owner ────────────────────────────────

  @IsTest
  static void emptyGroup_fallbackToOwner() {
    User owner = getUser('opportunity.owner@routertest.example.com');

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_Restricted' => new List<User>()
    };

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{
        buildRequest(true, false, owner.Email, owner.Id)
      }
    );
    Test.stopTest();

    Assert.areEqual(
      owner.Email,
      results[0].emailAddresses,
      'Empty group must fall back to owner email'
    );
    Assert.areEqual(
      1,
      results[0].recipientIds.size(),
      'Empty group must fall back to owner ID'
    );
    Assert.areEqual(String.valueOf(owner.Id), results[0].recipientIds[0]);
  }

  // ─── Test: Multiple members produce comma-separated email string ──────────

  @IsTest
  static void restrictedOpp_multipleMembers_commaSeparatedEmail() {
    User mem1 = getUser('restricted.member@routertest.example.com');
    User mem2 = getUser('topsecret.member@routertest.example.com');
    User owner = getUser('opportunity.owner@routertest.example.com');

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_Restricted' => new List<User>{ mem1, mem2 }
    };

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{
        buildRequest(true, false, owner.Email, owner.Id)
      }
    );
    Test.stopTest();

    Set<String> emails = splitEmails(results[0].emailAddresses);
    Assert.isTrue(
      emails.contains(mem1.Email),
      'First member email must be in the address string'
    );
    Assert.isTrue(
      emails.contains(mem2.Email),
      'Second member email must be in the address string'
    );
    Assert.areEqual(2, results[0].recipientIds.size());
  }

  // ─── Test: Mixed batch — normal and restricted in same call ───────────────

  @IsTest
  static void mixedBatch_normalAndRestrictedRequests() {
    User member = getUser('restricted.member@routertest.example.com');
    User owner = getUser('opportunity.owner@routertest.example.com');

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_Restricted' => new List<User>{ member }
    };

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{
        buildRequest(false, false, owner.Email, owner.Id),
        buildRequest(true, false, owner.Email, owner.Id)
      }
    );
    Test.stopTest();

    // Normal opp → owner
    Assert.areEqual(
      owner.Email,
      results[0].emailAddresses,
      'Normal opp must route to owner'
    );
    Assert.areEqual(String.valueOf(owner.Id), results[0].recipientIds[0]);

    // Restricted opp → group member
    Assert.areEqual(
      member.Email,
      results[1].emailAddresses,
      'Restricted opp must route to group member'
    );
    Assert.areEqual(String.valueOf(member.Id), results[1].recipientIds[0]);
  }

  // ─── Test: Bulk — 200 normal requests (short-circuit path) ───────────────

  @IsTest
  static void bulk_200NormalRequests_noGroupQuery() {
    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>();
    User owner = getUser('opportunity.owner@routertest.example.com');

    List<OpportunityEmailRouter.Request> requests = new List<OpportunityEmailRouter.Request>();
    for (Integer i = 0; i < 200; i++) {
      requests.add(buildRequest(false, false, owner.Email, owner.Id));
    }

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      requests
    );
    Test.stopTest();

    Assert.areEqual(200, results.size());
    Assert.areEqual(
      owner.Email,
      results[0].emailAddresses,
      'First result must route to owner'
    );
    Assert.areEqual(
      owner.Email,
      results[199].emailAddresses,
      'Last result must route to owner'
    );
  }

  // ─── Test: Bulk — 200 restricted requests ────────────────────────────────

  @IsTest
  static void bulk_200RestrictedRequests() {
    User member = getUser('restricted.member@routertest.example.com');
    User owner = getUser('opportunity.owner@routertest.example.com');

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_Restricted' => new List<User>{ member }
    };

    List<OpportunityEmailRouter.Request> requests = new List<OpportunityEmailRouter.Request>();
    for (Integer i = 0; i < 200; i++) {
      requests.add(buildRequest(true, false, owner.Email, owner.Id));
    }

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      requests
    );
    Test.stopTest();

    Assert.areEqual(200, results.size());
    Assert.areEqual(
      member.Email,
      results[0].emailAddresses,
      'First result must route to group member'
    );
    Assert.areEqual(
      member.Email,
      results[199].emailAddresses,
      'Last result must route to group member'
    );
  }
}
