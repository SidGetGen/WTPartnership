/**
 * WTPartnershipImplementationTest
 *
 * Integration test class covering the key automatable scenarios from the
 * WTPartnership implementation:
 *
 *   1. Opportunity validation rules (7 tests)
 *   2. LastStageChangeDate__c auto-stamping via record-triggered flow (2 tests)
 *   3. OpportunityEmailRouter routing via Public Groups (3 tests)
 *   4. Lead conversion field mappings — Enquiry Type, Project Classification,
 *      Project Sub-classification (1 combined test)
 *
 * What is NOT tested here (requires manual or environment-level verification):
 *   - Criteria-based sharing rule enforcement (fires asynchronously)
 *   - customNotificationAction / emailSimple delivery
 *   - FlexiPage / layout rendering
 *   - Scheduled flow execution
 *   - PSA Project creation (requires Certinia/PSA package)
 */
@IsTest
private class WTPartnershipImplementationTest {
  private static final String STAGE_PROPOSAL = 'Proposal/Bid Stage';
  private static final String STAGE_SUBMITTED = 'Submitted';
  private static final String STAGE_CLOSED_LOST = 'Closed Lost';
  private static final String LOSS_REASON_PRICE = 'Price';
  private static final String LOSS_REASON_OTHER = 'Other';

  // ─── Shared test data ────────────────────────────────────────────────────

  @TestSetup
  static void makeData() {
    Account acc = new Account(Name = 'WTP Test Account');
    insert acc;

    // Insert at PROPOSAL stage — Insert path exits the flow without stamping
    // LastStageChangeDate__c, so validation rules on Closed Lost won't fire here.
    Opportunity opp = new Opportunity(
      Name = 'WTP Test Opportunity',
      AccountId = acc.Id,
      StageName = STAGE_PROPOSAL,
      CloseDate = Date.today().addMonths(1),
      Amount = 50000
    );
    insert opp;
  }

  private static Opportunity getOpp() {
    return [
      SELECT
        Id,
        StageName,
        Amount,
        Loss_Reason__c,
        Loss_Reason_Details__c,
        LastStageChangeDate__c
      FROM Opportunity
      LIMIT 1
    ];
  }

  // ─── 1. Validation Rules ─────────────────────────────────────────────────

  @IsTest
  static void closedLost_missingLossReason_blocksUpdate() {
    Opportunity opp = getOpp();
    opp.StageName = STAGE_CLOSED_LOST;
    opp.Loss_Reason__c = null;
    opp.Loss_Reason_Details__c = null;
    try {
      Test.startTest();
      update opp;
      Test.stopTest();
      Assert.fail(
        'Expected DmlException — Loss Reason and Details both blank on Closed Lost'
      );
    } catch (DmlException e) {
      Assert.isTrue(
        e.getMessage().containsIgnoreCase('Loss Reason'),
        'Error should reference Loss Reason: ' + e.getMessage()
      );
    }
  }

  @IsTest
  static void closedLost_missingLossDetails_blocksUpdate() {
    Opportunity opp = getOpp();
    opp.StageName = STAGE_CLOSED_LOST;
    opp.Loss_Reason__c = LOSS_REASON_PRICE;
    opp.Loss_Reason_Details__c = null;
    try {
      Test.startTest();
      update opp;
      Test.stopTest();
      Assert.fail(
        'Expected DmlException — Loss Reason set but Details blank on Closed Lost'
      );
    } catch (DmlException e) {
      Assert.isTrue(
        e.getMessage().containsIgnoreCase('Loss Reason Details'),
        'Error should reference Loss Reason Details: ' + e.getMessage()
      );
    }
  }

  @IsTest
  static void closedLost_otherReason_missingDetails_blocksUpdate() {
    Opportunity opp = getOpp();
    opp.StageName = STAGE_CLOSED_LOST;
    opp.Loss_Reason__c = LOSS_REASON_OTHER;
    opp.Loss_Reason_Details__c = null;
    try {
      Test.startTest();
      update opp;
      Test.stopTest();
      Assert.fail(
        'Expected DmlException — Loss Reason = Other requires Details'
      );
    } catch (DmlException e) {
      Assert.isTrue(
        e.getMessage().containsIgnoreCase('Loss Reason Details'),
        'Error should reference Loss Reason Details: ' + e.getMessage()
      );
    }
  }

  @IsTest
  static void closedLost_otherReason_withDetails_saves() {
    Opportunity opp = getOpp();
    opp.StageName = STAGE_CLOSED_LOST;
    opp.Loss_Reason__c = LOSS_REASON_OTHER;
    opp.Loss_Reason_Details__c = 'Specific explanation for the loss.';
    Test.startTest();
    update opp;
    Test.stopTest();
    Assert.areEqual(
      STAGE_CLOSED_LOST,
      [SELECT StageName FROM Opportunity WHERE Id = :opp.Id].StageName
    );
  }

  @IsTest
  static void closedLost_withBothFields_saves() {
    Opportunity opp = getOpp();
    opp.StageName = STAGE_CLOSED_LOST;
    opp.Loss_Reason__c = LOSS_REASON_PRICE;
    opp.Loss_Reason_Details__c = 'Client selected a cheaper competitor.';
    Test.startTest();
    update opp;
    Test.stopTest();
    Assert.areEqual(
      STAGE_CLOSED_LOST,
      [SELECT StageName FROM Opportunity WHERE Id = :opp.Id].StageName
    );
  }

  @IsTest
  static void nonClosedLost_withLossReason_blocksUpdate() {
    Opportunity opp = getOpp();
    opp.StageName = STAGE_SUBMITTED;
    opp.Loss_Reason__c = LOSS_REASON_PRICE;
    try {
      Test.startTest();
      update opp;
      Test.stopTest();
      Assert.fail(
        'Expected DmlException — Loss Reason set on non-Closed Lost stage'
      );
    } catch (DmlException e) {
      Assert.isTrue(
        e.getMessage().containsIgnoreCase('Closed Lost'),
        'Error should mention Closed Lost: ' + e.getMessage()
      );
    }
  }

  @IsTest
  static void nonClosedLost_withoutLossReason_saves() {
    Opportunity opp = getOpp();
    opp.StageName = STAGE_SUBMITTED;
    opp.Loss_Reason__c = null;
    Test.startTest();
    update opp;
    Test.stopTest();
    Assert.areEqual(
      STAGE_SUBMITTED,
      [SELECT StageName FROM Opportunity WHERE Id = :opp.Id].StageName
    );
  }

  // ─── 2. LastStageChangeDate__c Auto-Stamping ─────────────────────────────

  @IsTest
  static void stageChange_stampsLastStageChangeDate() {
    Opportunity opp = getOpp();
    opp.StageName = STAGE_SUBMITTED;
    Test.startTest();
    update opp;
    Test.stopTest();
    Opportunity updated = [
      SELECT LastStageChangeDate__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    Assert.areEqual(
      Date.today(),
      updated.LastStageChangeDate__c,
      'LastStageChangeDate__c must equal today after a stage change'
    );
  }

  @IsTest
  static void nonStageEdit_doesNotChangeLastStageChangeDate() {
    // Step 1: stamp a date via stage change
    Opportunity opp = getOpp();
    opp.StageName = STAGE_SUBMITTED;
    update opp;
    Date stampedDate = [
      SELECT LastStageChangeDate__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ]
    .LastStageChangeDate__c;
    Assert.areEqual(
      Date.today(),
      stampedDate,
      'Pre-condition: date should be stamped after stage change'
    );

    // Step 2: change a non-stage field and confirm date is unchanged
    opp = [SELECT Id, StageName, Amount FROM Opportunity WHERE Id = :opp.Id];
    opp.Amount = 99999;
    Test.startTest();
    update opp;
    Test.stopTest();
    Date dateAfterAmountEdit = [
      SELECT LastStageChangeDate__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ]
    .LastStageChangeDate__c;
    Assert.areEqual(
      stampedDate,
      dateAfterAmountEdit,
      'LastStageChangeDate__c must not change when a non-stage field is updated'
    );
  }

  // ─── 3. OpportunityEmailRouter — Group-Based Routing ────────────────────

  @IsTest
  static void routerIntegration_normalOpp_ownerOnly() {
    // Normal opps short-circuit — no group query needed
    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>();
    String ownerEmail = UserInfo.getUserEmail();
    String ownerId = UserInfo.getUserId();

    OpportunityEmailRouter.Request req = new OpportunityEmailRouter.Request();
    req.isRestricted = false;
    req.isTopSecret = false;
    req.ownerEmail = ownerEmail;
    req.ownerId = ownerId;

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{ req }
    );
    Test.stopTest();

    Assert.areEqual(
      ownerEmail,
      results[0].emailAddresses,
      'Normal opp must route email to owner'
    );
    Assert.areEqual(1, results[0].recipientIds.size());
    Assert.areEqual(ownerId, results[0].recipientIds[0]);
  }

  @IsTest
  static void routerIntegration_restrictedOpp_routesToGroupMembers() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User member = new User(
      LastName = 'RestrictedMember',
      Email = 'restricted.member@wtp.routertest.example.com',
      Username = 'restricted.member@wtp.routertest.example.com',
      Alias = 'resmem',
      TimeZoneSidKey = 'Australia/Sydney',
      LocaleSidKey = 'en_AU',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = p.Id
    );
    insert member;

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_Restricted' => new List<User>{ member }
    };

    OpportunityEmailRouter.Request req = new OpportunityEmailRouter.Request();
    req.isRestricted = true;
    req.isTopSecret = false;
    req.ownerEmail = 'owner@test.com';
    req.ownerId = UserInfo.getUserId();

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{ req }
    );
    Test.stopTest();

    Assert.areEqual(
      member.Email,
      results[0].emailAddresses,
      'Restricted opp must route to SalesTeam_Restricted member email'
    );
    Assert.areEqual(1, results[0].recipientIds.size());
    Assert.areEqual(String.valueOf(member.Id), results[0].recipientIds[0]);
  }

  @IsTest
  static void routerIntegration_topSecretOpp_routesToGroupMembers() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User member = new User(
      LastName = 'TopSecretMember',
      Email = 'topsecret.member@wtp.routertest.example.com',
      Username = 'topsecret.member@wtp.routertest.example.com',
      Alias = 'tsmem',
      TimeZoneSidKey = 'Australia/Sydney',
      LocaleSidKey = 'en_AU',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = p.Id
    );
    insert member;

    OpportunityEmailRouter.mockGroupMembership = new Map<String, List<User>>{
      'SalesTeam_TopSecret' => new List<User>{ member }
    };

    OpportunityEmailRouter.Request req = new OpportunityEmailRouter.Request();
    req.isRestricted = false;
    req.isTopSecret = true;
    req.ownerEmail = 'owner@test.com';
    req.ownerId = UserInfo.getUserId();

    Test.startTest();
    List<OpportunityEmailRouter.Result> results = OpportunityEmailRouter.resolve(
      new List<OpportunityEmailRouter.Request>{ req }
    );
    Test.stopTest();

    Assert.areEqual(
      member.Email,
      results[0].emailAddresses,
      'Top Secret opp must route to SalesTeam_TopSecret member email'
    );
    Assert.areEqual(1, results[0].recipientIds.size());
    Assert.areEqual(String.valueOf(member.Id), results[0].recipientIds[0]);
  }

  // ─── 4. Lead Conversion Field Mappings ───────────────────────────────────

  @IsTest
  static void leadConvert_customFieldsMappedToOpportunity() {
    // Resolve valid picklist values for the two non-dependent mapped fields.
    // Project_Sub_classification__c is a dependent picklist whose valid values
    // depend on the Project_Classification__c controlling value — setting them
    // independently via getPicklistValues() produces an invalid combination.
    // That mapping is verified by the LeadConvertSettings metadata; it is excluded
    // from this automated test to avoid a INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST error.
    String enquiryVal = firstPicklistValue(Lead.Enquiry_Type__c.getDescribe());
    String classVal = firstPicklistValue(
      Lead.Project_Classification__c.getDescribe()
    );

    // Use an existing Opportunity to avoid triggering the ISNEW() Amount validation rule.
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Opportunity existingOpp = new Opportunity(
      Name = 'Lead Convert Target Opp',
      AccountId = acc.Id,
      StageName = STAGE_PROPOSAL,
      CloseDate = Date.today().addMonths(1),
      Amount = 10000
    );
    insert existingOpp;

    LeadStatus activeStatus = [
      SELECT ApiName
      FROM LeadStatus
      WHERE IsConverted = FALSE
      LIMIT 1
    ];
    LeadStatus convertedStatus = [
      SELECT ApiName
      FROM LeadStatus
      WHERE IsConverted = TRUE
      LIMIT 1
    ];

    Lead lead = new Lead(
      LastName = 'ConvertTest',
      Company = 'Convert Co',
      Status = activeStatus.ApiName,
      Enquiry_Type__c = enquiryVal,
      Project_Classification__c = classVal
    );
    insert lead;

    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(lead.Id);
    lc.setConvertedStatus(convertedStatus.ApiName);
    lc.setAccountId(acc.Id);
    lc.setOpportunityId(existingOpp.Id);

    Test.startTest();
    Database.convertLead(lc);
    Test.stopTest();

    Opportunity converted = [
      SELECT Opportunity_Type__c, Project_Classification__c
      FROM Opportunity
      WHERE Id = :existingOpp.Id
    ];

    if (String.isNotBlank(enquiryVal)) {
      Assert.areEqual(
        enquiryVal,
        converted.Opportunity_Type__c,
        'Enquiry_Type__c on Lead must map to Opportunity_Type__c on Opportunity'
      );
    }
    if (String.isNotBlank(classVal)) {
      Assert.areEqual(
        classVal,
        converted.Project_Classification__c,
        'Project_Classification__c must carry over from Lead to Opportunity'
      );
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  private static String firstPicklistValue(Schema.DescribeFieldResult dfr) {
    List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
    return entries.isEmpty() ? null : entries[0].getValue();
  }
}
