SQL Server Load & Address Matching

I need a T-SQL script that ingests two staging tables into our UPR_Master table. During the load the routine must normalize every address and, using the combination of account number plus that normalized address, compare each row against the existing customer address table as well as several case tables that also hold address data.

When a match exists, the script should write the relationship into our cross-reference (Xref) tables; when there is no match it should create a new master record and still register the linkage for audit purposes.

Please keep the solution in native SQL Server (2016 or later), wrap the whole process in a transaction for safe re-runs, and include straightforward error logging.

Deliverables

• A single, well-commented .sql file that:
 – loads property data from Stg_Table1 and Stg_Table2
 – applies the address-normalisation rules I will provide
 – Match the account-number + normalised-address comparison of both tables if match write a r
 – inserts/updates UPR_Master and use the address to match address in 3 other tables - Property, MPDU, CASE if match insert record into Xref and any other required tables
- write records into property-owner and property contact tables. Data is collected from the incoming two tables.
- unmatch or bad records are written into Review_Q tables for review,
Check a REF_RECORDTYPE table if property record type on incoming record is a 'CONDO' or 'APT' and weather it is a buildings with units, if its write the building and units records into building, Unit, unitOwner, unitcontact tables.
Write records into Status Change History tableI need a T-SQL script that ingests two staging tables into our UPR_Master table. During the load the routine must normalize every address and, using the combination of account number plus that normalized address, compare each row against the existing customer address table as well as several case tables that also hold address data.

When a match exists, the script should write the relationship into our cross-reference (Xref) tables; when there is no match it should create a new master record and still register the linkage for audit purposes.

Please keep the solution in native SQL Server (2016 or later), wrap the whole process in a transaction for safe re-runs, and include straightforward error logging.

Deliverables

• A single, well-commented .sql file that:
 – loads property data from Stg_Table1 and Stg_Table2
 – applies the address-normalisation rules I will provide
 – Match the account-number + normalised-address comparison of both tables if match write a r
 – inserts/updates UPR_Master and use the address to match address in 3 other tables - Property, MPDU, CASE if match insert record into Xref and any other required tables
- write records into property-owner and property contact tables. Data is collected from the incoming two tables.
- unmatch or bad records are written into Review_Q tables for review,
Check a REF_RECORDTYPE table if property record type on incoming record is a 'CONDO' or 'APT' and weather it is a buildings with units, if its write the building and units records into building, Unit, unitOwner, unitcontact tables.
Write records into Status Change History table
Write Audit Log table for all processing
Print statistics of record read and written
Provide a search script to Search the UPR Master with several search possibility,
Be available for further explanation on the project. To be complete ASAP.
• A brief README explaining assumptions, normalization logic, and run/rollback steps
• A small test script or dummy dataset showing the matching works as intended

Acceptance hinges on the script executing idempotently, matching accuracy, and clarity of in-line comments. Share any questions about table layouts and I’ll get the DDLs to you right away.
Write Audit Log table for all processing
Print statistics of record read and written
Provide a search script to Search the UPR Master with several search possibility,
Be available for further explanation on the project. To be complete ASAP.
• A brief README explaining assumptions, normalization logic, and run/rollback steps
• A small test script or dummy dataset showing the matching works as intended

Acceptance hinges on the script executing idempotently, matching accuracy, and clarity of in-line comments. Share any questions about table layouts and I’ll get the DDLs to you right away.