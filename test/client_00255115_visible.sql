/* Visible subset transcribed from Record_Account_00255115_SDAT_MA.docx,
   three spreadsheet screenshots supplied September 15, 2026.
   Disposable test database ONLY. This is not a complete account export.

   MA: 10 visible rows at 11215 OAK LEAF DR and 3 at 11235 OAK LEAF DR.
   Screenshots label these Building B/C; labels are annotations, not names.
   Cropped SDAT fields are omitted, not inferred from MA. NULL in those test
   columns means "not supplied in the attachment", not verified source NULL.
   DwellingUnits=746 is a source count, not a CondoUnit/UnitNumber value. */
USE UPRXDB_TEST;
GO

INSERT dbo.MAIncomingTableX1
    (MasterAddressID, Account, StreetNumber, StreetName, StreetType, Unit,
     City, ZipCode, LUCategory, ParcelNumber, XCoordinate, YCoordinate)
VALUES
 (390853,N'00255115',N'11215',N'OAK LEAF',N'DR',N'101',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313913,500144),
 (390854,N'00255115',N'11215',N'OAK LEAF',N'DR',N'102',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313911,500140),
 (390855,N'00255115',N'11215',N'OAK LEAF',N'DR',N'103',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313910,500137),
 (390856,N'00255115',N'11215',N'OAK LEAF',N'DR',N'104',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313909,500134),
 (390857,N'00255115',N'11215',N'OAK LEAF',N'DR',N'105',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313908,500130),
 (390858,N'00255115',N'11215',N'OAK LEAF',N'DR',N'106',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313906,500127),
 (390859,N'00255115',N'11215',N'OAK LEAF',N'DR',N'107',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313905,500125),
 (390860,N'00255115',N'11215',N'OAK LEAF',N'DR',N'108',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313917,500143),
 (390861,N'00255115',N'11215',N'OAK LEAF',N'DR',N'109',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313916,500138),
 (390862,N'00255115',N'11215',N'OAK LEAF',N'DR',N'110',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1313914,500135),
 (390353,N'255115',N'11235',N'OAK LEAF',N'DR',N'101',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1314122,500662),
 (390354,N'255115',N'11235',N'OAK LEAF',N'DR',N'102',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1314121,500660),
 (390355,N'255115',N'11235',N'OAK LEAF',N'DR',N'103',N'SILVER SPRING',N'20901',N'Multi-Family',N'390',1314119,500657);

/* Only fully visible SDAT fields used by the loader are transcribed.
   Owner and PremisesNumber are clipped; street/city/ZIP/CondoUnit are unseen. */
INSERT dbo.SDATIncomingTableX1
    (RealPropertyTaxInformationID, AccountNumber, Parcel, YearBuilt, DwellingUnits)
VALUES (22265, N'00255115', N'N390', 0, 746);
GO
