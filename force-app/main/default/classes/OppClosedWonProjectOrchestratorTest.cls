/**
 * OppClosedWonProjectOrchestratorTest
 *
 * Test coverage for OppClosedWonProjectOrchestrator.
 *
 * Prerequisites / deployment assumptions:
 *   - PSA (Certinia) package is installed: pse__Proj__c must be insertable.
 *   - Contact.User__c lookup field must exist (confirm API name with org schema).
 *   - Custom Opportunity fields used in mappings must exist in the org.
 *   - If pse__Proj__c has additional required fields beyond what is set here,
 *     add them to the makeData() helper before deploying to production.
 */
@isTest
private class OppClosedWonProjectOrchestratorTest {
  // ─── Shared test data ────────────────────────────────────────────────────

  @TestSetup
  static void makeData() {
    Account acc = new Account(
      Name = 'Test Account',
      BillingStreet = '123 Main St',
      BillingCity = 'Sydney',
      BillingState = 'NSW',
      BillingPostalCode = '2000',
      BillingCountry = 'Australia'
    );
    insert acc;

    Contact con = new Contact(
      LastName = 'Test Contact',
      AccountId = acc.Id,
      Email = 'testcontact@example.com',
      pse__Salesforce_User__c = UserInfo.getUserId()
    );
    insert con;

    Opportunity opp = new Opportunity(
      Name = 'Test Opp',
      AccountId = acc.Id,
      StageName = 'Prospecting',
      CloseDate = Date.today().addMonths(1),
      Amount = 50000,
      Estimated_Start_Date__c = Date.today(),
      Estimated_End_Date__c = Date.today().addMonths(3),
      Estimated_Construction_Costs__c = 20000
    );
    insert opp;

    Task t = new Task(
      WhatId = opp.Id,
      Subject = 'Follow-up call',
      Status = 'Not Started',
      Priority = 'Normal',
      ActivityDate = Date.today().addDays(7)
    );
    insert t;

    Event e = new Event(
      WhatId = opp.Id,
      Subject = 'Discovery meeting',
      StartDateTime = DateTime.now().addDays(3),
      EndDateTime = DateTime.now().addDays(3).addHours(1),
      DurationInMinutes = 60
    );
    insert e;
  }

  // ─── Happy path ──────────────────────────────────────────────────────────

  @isTest
  static void testHappyPath_createsProjectAndCopiesActivities() {
    Opportunity opp = [
      SELECT
        Id,
        Name,
        AccountId,
        Estimated_Start_Date__c,
        Estimated_End_Date__c,
        Estimated_Construction_Costs__c
      FROM Opportunity
      LIMIT 1
    ];
    Account acc = [
      SELECT
        BillingStreet,
        BillingCity,
        BillingState,
        BillingPostalCode,
        BillingCountry
      FROM Account
      LIMIT 1
    ];

    OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
    req.opportunityId = opp.Id;

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      new List<OppClosedWonProjectOrchestrator.Request>{ req }
    );
    Test.stopTest();

    // One result returned
    System.assertEquals(1, results.size(), 'Expected one result');
    System.assertEquals(opp.Id, results[0].opportunityId);
    System.assertNotEquals(
      null,
      results[0].projectId,
      'Project Id should be populated'
    );

    // Project created with correct field mappings
    pse__Proj__c proj = [
      SELECT
        Id,
        Name,
        pse__Stage__c,
        pse__Account__c,
        pse__Start_Date__c,
        pse__End_Date__c,
        A_Client_Project_Capital_Value__c,
        Security_classification__c,
        A_Client_Project_Address__c,
        W_Project_Suburb_City__c,
        W_Project_State__c,
        A_Project_Postcode__c,
        W_Project_Country__c
      FROM pse__Proj__c
      WHERE Id = :results[0].projectId
    ];
    System.assertEquals(
      opp.Name,
      proj.Name,
      'Project name should match Opportunity name'
    );
    System.assertEquals('Active', proj.pse__Stage__c);
    System.assertEquals(
      'Protected',
      proj.Security_classification__c,
      'Default classification should be Protected when neither flag is set'
    );
    System.assertEquals(
      opp.AccountId,
      proj.pse__Account__c,
      'Project Account should match Opportunity Account'
    );
    System.assertEquals(
      opp.Estimated_Start_Date__c,
      proj.pse__Start_Date__c,
      'Start date should be mapped'
    );
    System.assertEquals(
      opp.Estimated_End_Date__c,
      proj.pse__End_Date__c,
      'End date should be mapped'
    );
    System.assertEquals(
      opp.Estimated_Construction_Costs__c,
      proj.A_Client_Project_Capital_Value__c,
      'Capital value should match construction costs'
    );

    // Billing address should be copied to project (billing takes precedence over shipping)
    System.assertEquals(
      acc.BillingStreet,
      proj.A_Client_Project_Address__c,
      'Project address should use billing street'
    );
    System.assertEquals(
      acc.BillingCity,
      proj.W_Project_Suburb_City__c,
      'Project city should use billing city'
    );
    System.assertEquals(
      acc.BillingState,
      proj.W_Project_State__c,
      'Project state should use billing state'
    );
    System.assertEquals(
      acc.BillingPostalCode,
      proj.A_Project_Postcode__c,
      'Project postcode should use billing postcode'
    );
    System.assertEquals(
      acc.BillingCountry,
      proj.W_Project_Country__c,
      'Project country should use billing country'
    );

    // Task was COPIED to project (original still on Opportunity)
    List<Task> projTasks = [SELECT Id FROM Task WHERE WhatId = :proj.Id];
    System.assertEquals(
      1,
      projTasks.size(),
      'One task copy should exist on the project'
    );

    List<Task> oppTasks = [SELECT Id FROM Task WHERE WhatId = :opp.Id];
    System.assertEquals(
      1,
      oppTasks.size(),
      'Original task should remain on the Opportunity'
    );

    // Event was COPIED to project (original still on Opportunity)
    List<Event> projEvents = [SELECT Id FROM Event WHERE WhatId = :proj.Id];
    System.assertEquals(
      1,
      projEvents.size(),
      'One event copy should exist on the project'
    );

    List<Event> oppEvents = [SELECT Id FROM Event WHERE WhatId = :opp.Id];
    System.assertEquals(
      1,
      oppEvents.size(),
      'Original event should remain on the Opportunity'
    );
  }

  // ─── Project Director and Lead resolved from Contact.pse__Salesforce_User__c ──

  @isTest
  static void testProjectManagerMapped_whenContactExists() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
    Contact con = [SELECT Id FROM Contact LIMIT 1];

    OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
    req.opportunityId = opp.Id;

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      new List<OppClosedWonProjectOrchestrator.Request>{ req }
    );
    Test.stopTest();

    pse__Proj__c proj = [
      SELECT Id, pse__Project_Manager__c, A_Project_Lead__c
      FROM pse__Proj__c
      WHERE Id = :results[0].projectId
    ];
    System.assertEquals(
      con.Id,
      proj.pse__Project_Manager__c,
      'Project Director (pse__Project_Manager__c) should be resolved from Contact.pse__Salesforce_User__c'
    );
    System.assertEquals(
      con.Id,
      proj.A_Project_Lead__c,
      'Project Lead should be resolved from Contact.pse__Salesforce_User__c'
    );
  }

  // ─── Security classification variants ────────────────────────────────────

  @isTest
  static void testSecurityClassification_restricted() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Opportunity opp = new Opportunity(
      Name = 'Restricted Opp',
      AccountId = acc.Id,
      StageName = 'Prospecting',
      CloseDate = Date.today().addMonths(1),
      Amount = 10000,
      Restricted__c = true
    );
    insert opp;

    OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
    req.opportunityId = opp.Id;

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      new List<OppClosedWonProjectOrchestrator.Request>{ req }
    );
    Test.stopTest();

    pse__Proj__c proj = [
      SELECT Security_classification__c
      FROM pse__Proj__c
      WHERE Id = :results[0].projectId
    ];
    System.assertEquals(
      'Restricted',
      proj.Security_classification__c,
      'Restricted flag should produce Restricted classification'
    );
  }

  @isTest
  static void testSecurityClassification_topSecret() {
    Account acc = [SELECT Id FROM Account LIMIT 1];
    Opportunity opp = new Opportunity(
      Name = 'Top Secret Opp',
      AccountId = acc.Id,
      StageName = 'Prospecting',
      CloseDate = Date.today().addMonths(1),
      Amount = 10000,
      Top_Secret__c = true
    );
    insert opp;

    OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
    req.opportunityId = opp.Id;

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      new List<OppClosedWonProjectOrchestrator.Request>{ req }
    );
    Test.stopTest();

    pse__Proj__c proj = [
      SELECT Security_classification__c
      FROM pse__Proj__c
      WHERE Id = :results[0].projectId
    ];
    System.assertEquals(
      'Top Secret',
      proj.Security_classification__c,
      'Top Secret flag should take precedence and produce Top Secret classification'
    );
  }

  // ─── Activity field fidelity ──────────────────────────────────────────────

  @isTest
  static void testActivityFieldsCopiedCorrectly() {
    Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
    Task srcTask = [
      SELECT Subject, Status, Priority, ActivityDate
      FROM Task
      WHERE WhatId = :opp.Id
      LIMIT 1
    ];
    Event srcEvent = [
      SELECT Subject, StartDateTime, EndDateTime
      FROM Event
      WHERE WhatId = :opp.Id
      LIMIT 1
    ];

    OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
    req.opportunityId = opp.Id;

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      new List<OppClosedWonProjectOrchestrator.Request>{ req }
    );
    Test.stopTest();

    Id projId = results[0].projectId;

    Task copiedTask = [
      SELECT Subject, Status, Priority, ActivityDate
      FROM Task
      WHERE WhatId = :projId
      LIMIT 1
    ];
    System.assertEquals(
      srcTask.Subject,
      copiedTask.Subject,
      'Task Subject should be copied'
    );
    System.assertEquals(
      srcTask.Status,
      copiedTask.Status,
      'Task Status should be copied'
    );
    System.assertEquals(
      srcTask.Priority,
      copiedTask.Priority,
      'Task Priority should be copied'
    );
    System.assertEquals(
      srcTask.ActivityDate,
      copiedTask.ActivityDate,
      'Task ActivityDate should be copied'
    );

    Event copiedEvent = [
      SELECT Subject, StartDateTime, EndDateTime
      FROM Event
      WHERE WhatId = :projId
      LIMIT 1
    ];
    System.assertEquals(
      srcEvent.Subject,
      copiedEvent.Subject,
      'Event Subject should be copied'
    );
    System.assertEquals(
      srcEvent.StartDateTime,
      copiedEvent.StartDateTime,
      'Event StartDateTime should be copied'
    );
    System.assertEquals(
      srcEvent.EndDateTime,
      copiedEvent.EndDateTime,
      'Event EndDateTime should be copied'
    );
  }

  // ─── Opp with no activities ───────────────────────────────────────────────

  @isTest
  static void testNoActivities_projectStillCreated() {
    Account acc = new Account(Name = 'No Activity Account');
    insert acc;

    Opportunity opp = new Opportunity(
      Name = 'No Activity Opp',
      AccountId = acc.Id,
      StageName = 'Prospecting',
      CloseDate = Date.today().addMonths(1),
      Amount = 10000
    );
    insert opp;

    OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
    req.opportunityId = opp.Id;

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      new List<OppClosedWonProjectOrchestrator.Request>{ req }
    );
    Test.stopTest();

    System.assertNotEquals(
      null,
      results[0].projectId,
      'Project should be created even with no activities'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhatId = :results[0].projectId],
      'No tasks should exist on project'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Event WHERE WhatId = :results[0].projectId],
      'No events should exist on project'
    );
  }

  // ─── Null Opportunity Id in request ──────────────────────────────────────

  @isTest
  static void testNullOpportunityId_returnsEmptyList() {
    OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
    req.opportunityId = null;

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      new List<OppClosedWonProjectOrchestrator.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      results.size(),
      'Empty list expected when all inputs are null'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM pse__Proj__c],
      'No projects should be created'
    );
  }

  // ─── Shipping address used when no billing address ────────────────────────

  @isTest
  static void testShippingAddressFallback_whenNoBillingAddress() {
    Account acc = new Account(
      Name = 'Shipping Only Account',
      ShippingStreet = '99 Harbour Rd',
      ShippingCity = 'Brisbane',
      ShippingState = 'QLD',
      ShippingPostalCode = '4000',
      ShippingCountry = 'Australia'
    );
    insert acc;

    Opportunity opp = new Opportunity(
      Name = 'Shipping Fallback Opp',
      AccountId = acc.Id,
      StageName = 'Prospecting',
      CloseDate = Date.today().addMonths(1),
      Amount = 10000
    );
    insert opp;

    OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
    req.opportunityId = opp.Id;

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      new List<OppClosedWonProjectOrchestrator.Request>{ req }
    );
    Test.stopTest();

    pse__Proj__c proj = [
      SELECT
        A_Client_Project_Address__c,
        W_Project_Suburb_City__c,
        W_Project_State__c,
        A_Project_Postcode__c,
        W_Project_Country__c
      FROM pse__Proj__c
      WHERE Id = :results[0].projectId
    ];
    System.assertEquals(
      '99 Harbour Rd',
      proj.A_Client_Project_Address__c,
      'Should fall back to shipping street'
    );
    System.assertEquals(
      'Brisbane',
      proj.W_Project_Suburb_City__c,
      'Should fall back to shipping city'
    );
    System.assertEquals(
      'QLD',
      proj.W_Project_State__c,
      'Should fall back to shipping state'
    );
    System.assertEquals(
      '4000',
      proj.A_Project_Postcode__c,
      'Should fall back to shipping postcode'
    );
    System.assertEquals(
      'Australia',
      proj.W_Project_Country__c,
      'Should fall back to shipping country'
    );
  }

  // ─── Bulk: 200 Opportunities ──────────────────────────────────────────────

  @isTest
  static void testBulk_200Opportunities() {
    List<Account> accs = new List<Account>();
    for (Integer i = 0; i < 200; i++) {
      accs.add(new Account(Name = 'Bulk Account ' + i));
    }
    insert accs;

    List<Opportunity> opps = new List<Opportunity>();
    for (Integer i = 0; i < 200; i++) {
      opps.add(
        new Opportunity(
          Name = 'Bulk Opp ' + i,
          AccountId = accs[i].Id,
          StageName = 'Prospecting',
          CloseDate = Date.today().addMonths(1),
          Amount = 10000
        )
      );
    }
    insert opps;

    List<OppClosedWonProjectOrchestrator.Request> reqs = new List<OppClosedWonProjectOrchestrator.Request>();
    for (Opportunity opp : opps) {
      OppClosedWonProjectOrchestrator.Request req = new OppClosedWonProjectOrchestrator.Request();
      req.opportunityId = opp.Id;
      reqs.add(req);
    }

    Test.startTest();
    List<OppClosedWonProjectOrchestrator.Result> results = OppClosedWonProjectOrchestrator.process(
      reqs
    );
    Test.stopTest();

    System.assertEquals(200, results.size(), 'Expected 200 results');
    for (OppClosedWonProjectOrchestrator.Result r : results) {
      System.assertNotEquals(
        null,
        r.projectId,
        'Every result should have a projectId'
      );
    }
    System.assertEquals(
      200,
      [SELECT COUNT() FROM pse__Proj__c],
      '200 projects should have been inserted'
    );
  }
}
