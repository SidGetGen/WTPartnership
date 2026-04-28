/**
 * OppClosedWonProjectOrchestrator
 *
 * Invocable orchestrator called by Flow when an Opportunity transitions to
 * Closed Won.  Stage gating is the Flow's responsibility — this class trusts
 * that every supplied Opportunity Id is eligible and focuses solely on:
 *   1. Creating a linked PSA Project (pse__Proj__c)
 *   2. Copying all Tasks and Events from the Opportunity to the new Project
 *      (originals remain on the Opportunity; new copies are linked to the Project)
 *
 * Governor-limit budget per transaction (worst case, 200 Opps):
 *   SOQLs : 4  (Opportunities, Contacts, Tasks, Events)
 *   DMLs  : 3  (insert Projects, insert Task copies, insert Event copies)
 *
 * Contact-selection rule: when multiple Contacts share the same pse__Salesforce_User__c
 * value, the Contact with the earliest CreatedDate is chosen.  This is enforced by
 * ORDER BY CreatedDate ASC in the SOQL query combined with a containsKey guard
 * that ignores subsequent rows for the same user.
 *
 * Sharing: inherited sharing — delegates record visibility to the calling
 * context (the Flow's running user) rather than bypassing sharing rules
 * unconditionally.
 */
public inherited sharing class OppClosedWonProjectOrchestrator {
  // Opportunity Service_Line__c (multi-select) → pse__Proj__c Service_Line__c (single-select)
  private static final Map<String, String> SERVICE_LINE_MAP = new Map<String, String>{
    'Asset & FM' => 'Asset & Facilities Management',
    'Cost Management' => 'Cost Management & Quantity Surveying',
    'Cost Engineering' => 'Cost Management & Quantity Surveying',
    'Cost Engineering (Infra)' => 'Cost Management & Quantity Surveying',
    'Cost Engineering M&E' => 'Cost Management & Quantity Surveying',
    'Cost Planning' => 'Cost Management & Quantity Surveying',
    'Quantity Surveying' => 'Cost Management & Quantity Surveying',
    'Digital Services' => 'Digital Advisory',
    'Digital Transformation' => 'Digital Advisory',
    'P3 Advisory' => 'P3 & Project Delivery (US)',
    'Portfolio & Program Advisory' => 'Portfolio & Program Advisory',
    'Corporate Services' => 'Corporate Services',
    'Project Management Services' => 'Project Management (India)'
  };

  // ─── Invocable Request DTO ───────────────────────────────────────────────

  public class Request {
    @InvocableVariable(label='Opportunity Id' required=true)
    public Id opportunityId;
  }

  // ─── Invocable Result DTO ────────────────────────────────────────────────

  public class Result {
    @InvocableVariable(label='Opportunity Id')
    public Id opportunityId;

    @InvocableVariable(label='Created Project Id')
    public Id projectId;
  }

  // ─── Invocable Entry Point ───────────────────────────────────────────────

  @InvocableMethod(
    label='Create Project from Closed Won Opportunity'
    description='Creates a PSA Project from a Closed Won Opportunity and copies all related Tasks and Events to the new Project. Stage gating must be handled by the calling Flow.'
    category='Opportunity'
  )
  public static List<Result> process(List<Request> requests) {
    // ── 1. Collect non-null Opportunity Ids ─────────────────────────────
    Set<Id> oppIds = new Set<Id>();
    for (Request req : requests) {
      if (req.opportunityId != null) {
        oppIds.add(req.opportunityId);
      }
    }
    if (oppIds.isEmpty()) {
      return new List<Result>();
    }

    // ── 2. SOQL 1 — Opportunities + Account address fields ──────────────
    Map<Id, Opportunity> oppById = new Map<Id, Opportunity>(
      [
        SELECT
          Id,
          Name,
          AccountId,
          OwnerId,
          Project_Lead__c,
          Estimated_Start_Date__c,
          Estimated_End_Date__c,
          Service_Line__c,
          Project_Classification__c,
          Project_Sub_classification__c,
          ExpectedRevenue,
          Estimated_Construction_Costs__c,
          Restricted__c,
          Top_Secret__c,
          Account.BillingStreet,
          Account.BillingCity,
          Account.BillingState,
          Account.BillingPostalCode,
          Account.BillingCountry,
          Account.ShippingStreet,
          Account.ShippingCity,
          Account.ShippingState,
          Account.ShippingPostalCode,
          Account.ShippingCountry
        FROM Opportunity
        WHERE Id IN :oppIds
      ]
    );

    // ── 3. Collect owner + project lead User Ids for Contact resolution ────
    Set<Id> ownerUserIds = new Set<Id>();
    for (Opportunity opp : oppById.values()) {
      ownerUserIds.add(opp.OwnerId);
      if (opp.Project_Lead__c != null) {
        ownerUserIds.add(opp.Project_Lead__c);
      }
    }

    // ── 4. SOQL 2 — Contacts linked to owner Users ──────────────────────
    // ORDER BY CreatedDate ASC + containsKey guard: earliest-created Contact
    // per user wins when multiple Contacts share the same pse__Salesforce_User__c.
    Map<Id, Id> userIdToContactId = new Map<Id, Id>();
    for (Contact c : [
      SELECT Id, pse__Salesforce_User__c
      FROM Contact
      WHERE pse__Salesforce_User__c IN :ownerUserIds
      ORDER BY CreatedDate ASC
    ]) {
      if (!userIdToContactId.containsKey(c.pse__Salesforce_User__c)) {
        userIdToContactId.put(c.pse__Salesforce_User__c, c.Id);
      }
    }

    // ── 5. Build Project records in memory ──────────────────────────────
    List<pse__Proj__c> projectsToInsert = new List<pse__Proj__c>();
    Map<Id, pse__Proj__c> projectByOppId = new Map<Id, pse__Proj__c>();

    for (Opportunity opp : oppById.values()) {
      pse__Proj__c proj = new pse__Proj__c();

      proj.Name = opp.Name;
      proj.pse__Account__c = opp.AccountId;
      proj.pse__Project_Manager__c = userIdToContactId.get(opp.OwnerId);
      proj.A_Project_Lead__c = userIdToContactId.get(opp.Project_Lead__c);
      proj.pse__Start_Date__c = opp.Estimated_Start_Date__c;
      proj.pse__End_Date__c = opp.Estimated_End_Date__c;
      // Service_Line__c is multi-select on Opportunity but single-select on
      // pse__Proj__c, and the two picklists use different value sets — map
      // the first selected Opportunity value; unmapped values become null.
      proj.Service_Line__c = String.isNotBlank(opp.Service_Line__c)
        ? SERVICE_LINE_MAP.get(opp.Service_Line__c.split(';')[0].trim())
        : null;
      proj.A_Project_Classification__c = opp.Project_Classification__c;
      proj.W_Project_Subclassification__c = opp.Project_Sub_classification__c;
      proj.A_Estimated_Contract_Value__c = opp.ExpectedRevenue;
      proj.A_Client_Project_Capital_Value__c = opp.Estimated_Construction_Costs__c;
      proj.Security_classification__c = opp.Top_Secret__c == true
        ? 'Top Secret'
        : (opp.Restricted__c == true ? 'Restricted' : 'Protected');
      proj.pse__Stage__c = 'Active';

      if (opp.Account != null) {
        // 1. Check if the Billing Address contains any data
        Boolean hasBillingAddress =
          String.isNotBlank(opp.Account.BillingStreet) ||
          String.isNotBlank(opp.Account.BillingCity) ||
          String.isNotBlank(opp.Account.BillingState) ||
          String.isNotBlank(opp.Account.BillingPostalCode) ||
          String.isNotBlank(opp.Account.BillingCountry);

        // 2. Check if the Shipping Address contains any data
        Boolean hasShippingAddress =
          String.isNotBlank(opp.Account.ShippingStreet) ||
          String.isNotBlank(opp.Account.ShippingCity) ||
          String.isNotBlank(opp.Account.ShippingState) ||
          String.isNotBlank(opp.Account.ShippingPostalCode) ||
          String.isNotBlank(opp.Account.ShippingCountry);

        // 3. Apply the appropriate address block
        if (hasBillingAddress) {
          proj.A_Client_Project_Address__c = opp.Account.BillingStreet;
          proj.W_Project_Suburb_City__c = opp.Account.BillingCity;
          proj.W_Project_State__c = opp.Account.BillingState;
          proj.A_Project_Postcode__c = opp.Account.BillingPostalCode;
          proj.W_Project_Country__c = opp.Account.BillingCountry;
        } else if (hasShippingAddress) {
          proj.A_Client_Project_Address__c = opp.Account.ShippingStreet;
          proj.W_Project_Suburb_City__c = opp.Account.ShippingCity;
          proj.W_Project_State__c = opp.Account.ShippingState;
          proj.A_Project_Postcode__c = opp.Account.ShippingPostalCode;
          proj.W_Project_Country__c = opp.Account.ShippingCountry;
        }
      }

      projectsToInsert.add(proj);
      projectByOppId.put(opp.Id, proj);
    }

    // ── 6. DML 1 — Insert Projects ───────────────────────────────────────
    insert projectsToInsert;

    // Build Opp Id → inserted Project Id map
    Map<Id, Id> projectIdByOppId = new Map<Id, Id>();
    for (Id oppId : projectByOppId.keySet()) {
      projectIdByOppId.put(oppId, projectByOppId.get(oppId).Id);
    }

    // ── 7. SOQL 3 — Tasks on source Opportunities (copy, not re-parent) ──
    List<Task> tasksToCopy = new List<Task>();
    for (Task t : [
      SELECT
        Id,
        WhatId,
        WhoId,
        Subject,
        Status,
        Priority,
        ActivityDate,
        Description,
        OwnerId,
        Type
      FROM Task
      WHERE WhatId IN :oppIds
    ]) {
      Id newProjectId = projectIdByOppId.get(t.WhatId);
      if (newProjectId != null) {
        tasksToCopy.add(
          new Task(
            WhatId = newProjectId,
            WhoId = t.WhoId,
            Subject = t.Subject,
            Status = t.Status,
            Priority = t.Priority,
            ActivityDate = t.ActivityDate,
            Description = t.Description,
            OwnerId = t.OwnerId,
            Type = t.Type
          )
        );
      }
    }

    // ── 8. SOQL 4 — Events on source Opportunities (copy, not re-parent) ─
    List<Event> eventsToCopy = new List<Event>();
    for (Event e : [
      SELECT
        Id,
        WhatId,
        WhoId,
        Subject,
        StartDateTime,
        EndDateTime,
        Description,
        OwnerId,
        Location,
        IsAllDayEvent,
        Type
      FROM Event
      WHERE WhatId IN :oppIds
    ]) {
      Id newProjectId = projectIdByOppId.get(e.WhatId);
      if (newProjectId != null) {
        eventsToCopy.add(
          new Event(
            WhatId = newProjectId,
            WhoId = e.WhoId,
            Subject = e.Subject,
            StartDateTime = e.StartDateTime,
            EndDateTime = e.EndDateTime,
            Description = e.Description,
            OwnerId = e.OwnerId,
            Location = e.Location,
            IsAllDayEvent = e.IsAllDayEvent,
            Type = e.Type
          )
        );
      }
    }

    // ── 9. DML 2 & 3 — Insert activity copies ───────────────────────────
    if (!tasksToCopy.isEmpty()) {
      insert tasksToCopy;
    }
    if (!eventsToCopy.isEmpty()) {
      insert eventsToCopy;
    }

    // ── 10. Build and return results ─────────────────────────────────────
    List<Result> results = new List<Result>();
    for (Id oppId : projectIdByOppId.keySet()) {
      Result r = new Result();
      r.opportunityId = oppId;
      r.projectId = projectIdByOppId.get(oppId);
      results.add(r);
    }
    return results;
  }
}
