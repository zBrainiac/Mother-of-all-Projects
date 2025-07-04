/****** Object:  StoredProcedure [BBG].[getIndexMarketDataByOICode]    Script Date: 03/07/2025 15:01:11 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER     proc [BBG].[getIndexMarketDataByOICode] @OIIndex varchar(max),@ccy varchar(max),@fromdate datetime, @todate datetime,@jsonTickerstr varchar(max) as
begin
	set nocount on

		/*	Function:	get Bloomberg Market data, called by [Ref].[getIndexDataByOICodeList]

		Notes on operation:- 

			A Market data row consists of Valuedate, Identifier(ticker), Value, type(Net return etc), and currency (if ccy not specified, the local will be used)
	
		Process to achieve this...

			set constants

			get map of tickers from json param-->gettickermap proc called by parent sproc

			get list of currencies

			get market data joined to itself to get the ccy code-->>every data row should have a matching ccy row
				add on the id of the request that generated this data

			compute the % change for between consecutive days

			determine if it's the local ccy or not --> hedged
	
		Change History:
				Date		Id	Auth	Notes
				01.08.2023	0	PJR		Initial version
				02.07.2024	1	PJR		The oi list table is now not required
				10.07.2024	2	PJR		Hedging relabels the result set with the desired ccy although it is still the hedged ccy
				30.07.2024	3	PJR		The fieldmnemonic TOT_RETURN_NET_DVDS is a dynamic calc, topups or any new additional rows will not have a contiguous value
										and because the ticker does not change it needs the fileimportid to be used to determine when the new batch starts.
										The new batch of this fieldmnemonic type will require the overlapping row to determine how to calc the daily delta%.

	*/

	--bbg constants

	--change 3.0
	declare	@OverlapRecordIndicator varchar(32)='-9999999'	--ignore rows with this, it is used for the handling of fieldmnemonic types that are recalculated eg. TOT_RETURN_NET_DVDS

	declare	@quotedccyId	int=(select id from BBG.attributeuniverse	where fieldmnemonic='quoted_crncy')
			,@isoccy		int=(select id from BBG.attributeuniverse	where fieldmnemonic='ISOCCY')
			,@LocalCcyId	int=(select id from BBG.attributeuniverse	where fieldmnemonic='local_crncy')
			,@SecProviderId	int=(Select Id from Ref.SecurityProvider	where ProviderName='Bloomberg')

	declare @reqGrpId	table(fkSecurityProviderId int,fkRequestGroupId int)
	insert @reqGrpId(fkSecurityProviderId,fkRequestGroupId) 
		select @SecProviderId,id from BBG.RequestGroup			where requestgroupdesc='Risk Indices 001'

	/*the ticker map holds the linked list of tickers including backfill/cutover dates
	*/
	declare @TickerMap table (Id int,ParentId int,fkSourceProviderId int,fkidentifierid int,fkfieldDescriptionId int,[level] int,ActiveFrom datetime,ActiveTo datetime,OICode varchar(128),PrimaryTicker varchar(128),Ccy varchar(32));
	insert @TickerMap(Id,ParentId,fkSourceProviderId,fkidentifierid,fkfieldDescriptionId,[level],ActiveTo,ActiveFrom,OICode,PrimaryTicker)
	select * from openjson(@jsonTickerstr)
	with (	Id						int			'$.Id',
			ParentId				int			'$.ParentId',
			fkSourceProviderId		int			'$.fkSourceProviderId',
			fkidentifierid			int			'$.fkidentifierid',
			fkfieldDescriptionId	int			'$.fkfieldDescriptionId',
			level					int			'$.level',
			ActiveTo				datetime	'$.ActiveTo',
			ActiveFrom				datetime	'$.ActiveFrom',
			OICode					varchar(128)'$.OICode',
			PrimaryTicker			varchar(128)'$.PrimaryTicker')

	/*the ticker copy map holds the linked list of tickers including backfill/cutover dates
		but is adjusted to accomodate the ovelap dates for calc of % daily delta.
	*/
	declare @TickerMapCopy table (Id int,ParentId int,fkSourceProviderId int,fkidentifierid int,fkfieldDescriptionId int,[level] int,ActiveFrom datetime,ActiveTo datetime,OICode varchar(128),PrimaryTicker varchar(128),Ccy varchar(32));
	insert @TickerMapCopy(Id,ParentId,fkSourceProviderId,fkidentifierid,fkfieldDescriptionId,[level],ActiveTo,ActiveFrom,OICode,PrimaryTicker)
			select Id,ParentId,fkSourceProviderId,fkidentifierid,fkfieldDescriptionId,[level],ActiveTo,ActiveFrom,OICode,PrimaryTicker from @TickerMap
	
	declare @i int,@iMax int
	select @i=min(id),@iMax=max(id) from @TickerMapCopy
	while @i is not null begin
		update @TickerMapCopy set Activefrom=(select ActiveTo from @TickerMapCopy where parentid=@i) where id=@i and id<@iMax
		set @i=(select min(id) from @TickerMapCopy where id>@i and id<@iMax)
	end

	declare @CcyList			table (Ccy varchar(32),fkSecurityProviderId int not null)
	declare @defaultCcyList		table (IdentifierId int, Identifier varchar(32),LocalCurrency varchar(32))
	declare @defaultTicker		varchar(32)=
		(select min(fkIdentifierid) from @TickerMapCopy where fkSourceProviderId=@SecProviderId and level=(select min(level) from @TickerMapCopy where fkSourceProviderId=@SecProviderId))

	--assume 1 ccy
--select * from @TickerMapCopy

	--default to local if hedged
	declare @isHedged int=(select ishedged from ref.BenchMarkOICodes where OICode=@OIIndex)
	declare @HedgeCcy varchar(32)=@ccy
	select @ccy=case when @isHedged=1 then '' else @ccy end
--select @isHedged
--if ccy blank get quoted ccy
	if isnull(@ccy,'')='' begin
		insert @defaultCcyList(IdentifierId,Identifier,LocalCurrency)
			select tlm.fkIdentifierId IdentifierId,sid.Identifier,iso.ISOCcy LocalCurrency
			from	[Ref].[TickerLocalCurrencyMap]	tlm
			join	ref.SecurityIdentifier			sid	on	sid.Id=tlm.fkIdentifierId
			join	ref.ISOCurrency					iso	on	iso.id=tlm.fkLocalCurrencyMapId
			where	tlm.fkSecurityProviderId=@SecProviderId 
				and sid.id in (select fkIdentifierid from @TickerMapCopy			-- DC 26 Sep 2024
								where fkSourceProviderId=@SecProviderId)
				--and sid.id=(select MIN(fkIdentifierid) from @TickerMapCopy
				--				where fkSourceProviderId=@SecProviderId and [level]=(select min(level) from @TickerMapCopy where fkSourceProviderId=@SecProviderId))

		insert @CcyList(Ccy,fkSecurityProviderId)select distinct LocalCurrency,1 from @defaultCcyList -- DC 30 Sep 2024 - insert distinct ccy

	end
	else
		insert @CcyList(Ccy,fkSecurityProviderId)	select distinct item,@SecProviderId from dbo.SplitString(@ccy,',')

----------------------------------------------------------------------------------------------------------------------------------------
/*change	3.1 ticker data overlap fix
*/
	declare @MarketDataOverLapCheck table(Id int identity(1,1), fkRequestControlId int, Valuedate datetime , FieldValue varchar(64) , fkfielddescriptionId int,fkIdentifierId int,[Level] int,FieldMnemonic varchar(255),isOverLap bit,fkImportFilenameId int,SourceStatusCode varchar(255))
	declare @MarketDataOverLapCheck2 table(Id int identity(1,1), fkRequestControlId int, Valuedate datetime , FieldValue varchar(64) , fkfielddescriptionId int,fkIdentifierId int,[Level] int,FieldMnemonic varchar(255),isOverLap bit,fkImportFilenameId int,SourceStatusCode varchar(255))

	declare @MarketData table(Id int identity(1,1), fkRequestControlId int, Valuedate datetime , FieldValue varchar(64) , fkfielddescriptionId int,fkIdentifierId int,[Level] int)
	declare @unqIdentifierAttribute table (Id int identity(1,1),fkIdentifierId int,fkfieldDescriptionId int,fkImportFilenameId int)

	create table #MarketDataChange (Id int identity(1,1),fkIdentifierId int,fkFieldDescriptionId int,prevdate datetime,prevvalue decimal(38,20),nextdate datetime,nextvalue decimal(38,20),ChangePercent decimal(38,20),fkImportFilenameId int)

	insert  @MarketDataOverLapCheck (fkRequestControlId , Valuedate  , FieldValue  , fkfielddescriptionId ,fkIdentifierId,[Level],FieldMnemonic,isOverLap,fkImportFilenameId,SourceStatusCode)
		select	md.fkRequestControlId,
				md.valuedate,
				md.fieldvalue,
				md.fkfielddescriptionid,
				md.fkIdentifierId,
				mp.[Level],
				au.FieldMnemonic,
				0, --case when md.SourceStatuscode=@OverlapRecordIndicator then 1 else 0 end,
				md.fkImportFilenameId,
				md.SourceStatuscode
--select*
		from		BBG.RequestGroupItem		rgi
		join		BBG.MarketData				md			on	md.fkrequestcontrolid		=rgi.fkrequestcontrolid
		join		@TickerMapCopy				mp			on	mp.fkIdentifierId			=md.fkIdentifierId	and mp.fkFieldDescriptionId=md.fkFieldDescriptionId and md.ValueDate>=mp.ActiveFrom and md.ValueDate<=mp.ActiveTo
		join		BBG.AttributeUniverse		au			on	au.id						=mp.fkfielddescriptionid
		left join	BBG.MarketData				mdlclccy	on	mdlclccy.fkrequestcontrolid	=md.fkrequestcontrolid
															and mdlclccy.valuedate			=md.valuedate
															and	mdlclccy.fkIdentifierId		=md.fkIdentifierId
															and mdlclccy.fkFieldDescriptionId=@quotedccyId
--change 3.2 added
															and mdlclccy.fkImportFilenameId=md.fkImportFilenameId
--
		join	@CcyList					ccy			on	convert(varbinary,ccy.Ccy)		=convert(varbinary,mdlclccy.FieldValue)

		where	rgi.fkRequestGroupId	in (select fkRequestGroupId from @reqgrpid where fkSecurityProviderId=@SecProviderId)
		and		au.fieldmnemonic		<>'local_crncy'
--and md.Valuedate>='27 jul 2024'
		order by md.ValueDate,mp.[level] desc --force correct sequence

--select '1',* from @MarketDataOverLapCheck order by fkImportFilenameId,Valuedate
--goto okexit		
		/*Overlaps are dealt with seperately
		*/
		
		/*change 3.3 look for overlaps
		*/
		if exists(	select count(*) overlaps,fkIdentifierId,valuedate,fkfielddescriptionId
					from @MarketDataOverLapCheck
					group by fkIdentifierId,valuedate,fkfielddescriptionId
					having count(*)>1
					)
			begin
--select '2'
			--rmv any rows in a batch that are before the overlap row
				delete @MarketDataOverLapCheck where id in (
						select min(id) Id
						from @MarketDataOverLapCheck ol
						where Id<(select min(Id) 
									from @MarketDataOverLapCheck 
									where fkImportFilenameId=ol.fkImportFilenameId and sourceStatusCode=@OverlapRecordIndicator)
						group by fkIdentifierId,valuedate,fkfielddescriptionId,fkImportFilenameId
				)

				--the 1st of ea group of tickers, this is the overlap row
				update @MarketDataOverLapCheck set isOverLap=1 where SourceStatusCode=@OverlapRecordIndicator

				insert  @MarketDataOverLapCheck2 (fkRequestControlId , Valuedate  , FieldValue  , fkfielddescriptionId ,fkIdentifierId,[Level],FieldMnemonic,isOverLap,fkImportFilenameId,SourceStatusCode)
					select fkRequestControlId , Valuedate  , FieldValue  , fkfielddescriptionId ,fkIdentifierId,[Level],FieldMnemonic,isOverLap,fkImportFilenameId,SourceStatusCode 
						from @MarketDataOverLapCheck
						order by fkImportFilenameId,fkidentifierid,valuedate

--select '3',* from @MarketDataOverLapCheck2 where Valuedate>='25 jul 2024' order by fkImportFilenameId,id
--goto okexit
				--get a list of tickers that have olaps
				insert @unqIdentifierAttribute(fkIdentifierId ,fkfieldDescriptionId,fkImportFilenameId) 
					select distinct fkIdentifierId ,fkfieldDescriptionId,fkImportFilenameId 
					from @MarketDataOverLapCheck2 where isOverLap=1

--select * from @unqIdentifierAttribute

				--compute the delta % for ea ticker within the overlapping batch
				insert #MarketDataChange (fkIdentifierId,fkFieldDescriptionId,prevdate ,prevvalue ,nextdate ,nextvalue ,ChangePercent,fkImportFilenameId)
				select 	 r.fkIdentifierId,r.fkfielddescriptionId
						,p.valuedate prevdate ,p.fieldvalue prevvalue
						,r.valuedate nextdate ,r.fieldvalue nextvalue
						,(convert(float,r.FieldValue)-convert(float,p.FieldValue))/p.fieldvalue ChangePercent
						,u.fkImportFilenameId
--select *
				from	@unqIdentifierAttribute	u
				join	@MarketDataOverLapCheck2 r	on	r.fkIdentifierId=u.fkIdentifierId and r.fkfielddescriptionId=u.fkfieldDescriptionId and r.fkImportFilenameId=u.fkImportFilenameId
				join	@MarketDataOverLapCheck2 p	on	p.id=r.id-1 and p.fkImportFilenameId=r.fkImportFilenameId
				where isnumeric(r.FieldValue)=1
--goto okexit
				--get a list of tickers that do not have olaps
				delete @unqIdentifierAttribute
				
				insert @unqIdentifierAttribute(fkIdentifierId ,fkfieldDescriptionId,fkImportFilenameId) 
					select distinct fkIdentifierId ,fkfieldDescriptionId,ol.fkImportFilenameId 
					from @MarketDataOverLapCheck2 ol
					left join (select distinct fkImportFilenameId from @MarketDataOverLapCheck where isOverLap=1) impF on impf.fkImportFilenameId=ol.fkImportFilenameId
					where impf.fkImportFilenameId is null

				--compute the delta % for ea ticker within the NON overlapping batch
				insert #MarketDataChange (fkIdentifierId,fkFieldDescriptionId,prevdate ,prevvalue ,nextdate ,nextvalue ,ChangePercent,fkImportFilenameId)
				select 	 r.fkIdentifierId,r.fkfielddescriptionId
						,p.valuedate prevdate ,p.fieldvalue prevvalue
						,r.valuedate nextdate ,r.fieldvalue nextvalue
						,(convert(float,r.FieldValue)-convert(float,p.FieldValue))/p.fieldvalue ChangePercent
						,u.fkImportFilenameId
				from	@unqIdentifierAttribute	u
				join	@MarketDataOverLapCheck2 r	on	r.fkIdentifierId=u.fkIdentifierId and r.fkfielddescriptionId=u.fkfieldDescriptionId and r.fkImportFilenameId=u.fkImportFilenameId
				join	@MarketDataOverLapCheck2 p	on	p.id=r.id-1
				where isnumeric(r.FieldValue)=1

--select '3.1',* from #MarketDataChange where prevdate>'25 jul 2024' order by prevdate;goto okexit

				select	mp.OICode,
								md.valuedate,
								convert(varchar(32),md.valuedate,106)	displayvaluedate
								,PrimaryTicker
								,case when md.identifier<>mp.PrimaryTicker then md.identifier else '' end BackfillTicker
								,case when isnumeric(md.fieldvalue)=1 and md.fieldvalue is not null then
									convert(varchar(50),convert(decimal(38,10),md.fieldvalue))
								else
									md.fieldvalue
								end FieldValue,
								au.fieldmnemonic,
								isnull(mdc.ChangePercent,0.0) ChangePercent,
				--mdlclccy.*
				-- Change 2.1
								case when @isHedged=1 
									then 
										case when @HedgeCcy<>''
											then	@HedgeCcy
											else
												--get local
												(select	iso.ISOCcy 
												from ref.securityidentifier		sid 
												join ref.TickerLocalCurrencyMap m	on sid.id=m.fkIdentifierId 
												left join ref.ISOCurrency		iso on iso.id=m.fkLocalCurrencyMapId
												where m.fkSecurityProviderId=1 and sid.Identifier=md.Identifier
												)
										end
									else 
										case when isnull(mdlclccy.fieldvalue,'')<>'' 
												then	mdlclccy.fieldvalue
											else
												case when charindex('~',au.fieldmnemonic)>0
													then replace(au.fieldmnemonic,substring(au.fieldmnemonic,1,charindex('~',au.fieldmnemonic)),'')
													else ''
												end
										end
								end Currency,

								case when isnull(mdlclccy.fieldvalue,'')<>'' 
									then	
										case when @isHedged=1 and isnull(mdlclccy.fieldvalue,'')<>@HedgeCcy and @HedgeCcy<>''
											then 'N' 
											else 'Y' 
										end
									else
										'N'
								end		isLocal
				--select *
						from		BBG.RequestGroupItem		rgi
						join		BBG.MarketData				md			on	md.fkrequestcontrolid		=rgi.fkrequestcontrolid
						join		@TickerMap					mp			on	mp.fkIdentifierId			=md.fkIdentifierId
																			and mp.fkFieldDescriptionId		=md.fkFieldDescriptionId
						join		BBG.AttributeUniverse		au			on	au.id						=mp.fkfielddescriptionid

						left join	BBG.MarketData				mdlclccy	on	mdlclccy.fkrequestcontrolid	=md.fkrequestcontrolid
																			and mdlclccy.valuedate			=md.valuedate
																			and	mdlclccy.fkIdentifierId		=md.fkIdentifierId
																			and mdlclccy.fkFieldDescriptionId=@quotedccyId
				--change 3.3 added
																			and mdlclccy.fkImportFilenameId		=md.fkImportFilenameId
															
						join	#MarketDataChange				mdc		on	mdc.fkIdentifierId			=md.fkIdentifierId 
																			and	mdc.fkFieldDescriptionId	=md.fkFieldDescriptionId 
																			and mdc.nextdate				=md.ValueDate
				--change 3.4 added
																			and mdc.fkImportFilenameId		=md.fkImportFilenameId

						join		@CcyList					ccy			on	convert(binary,ccy.Ccy)=convert(binary,mdlclccy.FieldValue)
						left join	ref.TickerLocalCurrencyMap	tlm			on	tlm.fkIdentifierId=md.fkIdentifierId and tlm.fkSecurityProviderId=@SecProviderId
						left join	ref.ISOCurrency				ISOcy		on	ISOcy.Id=tlm.fkLocalCurrencyMapId

						where	rgi.fkRequestGroupId	in (select fkRequestGroupId from @reqgrpid where fkSecurityProviderId=@SecProviderId)
						and		au.fieldmnemonic		not in ('quoted_crncy')
						and		mp.fkSourceProviderId	=@SecProviderId
						and		md.ValueDate			between mp.ActiveFrom and mp.ActiveTo
						and		mdlclccy.id is not null
						and		case when isnull(@ccy,'')<>'' then
										case	when isnull(mdlclccy.fieldvalue,'')<>'' 
													then	mdlclccy.fieldvalue
												else ''
										end 
									else mdlclccy.fieldvalue
								end 
								= case when isnull(@ccy,'')<>'' then @ccy else isnull(mdlclccy.fieldvalue,'') end
						order by md.ValueDate
			end
		else
			/* non-overlapping data
			*/
			begin
--select 'no'
				insert  @MarketData(fkRequestControlId , Valuedate  , FieldValue  , fkfielddescriptionId ,fkIdentifierId,[Level])
				select	md.fkRequestControlId,
						md.valuedate,
						md.fieldvalue,
						md.fkfielddescriptionid,
						md.fkIdentifierId,
						mp.[Level]
--select*
				from		BBG.RequestGroupItem		rgi
				join		BBG.MarketData				md			on	md.fkrequestcontrolid		=rgi.fkrequestcontrolid
				join		@TickerMapCopy				mp			on	mp.fkIdentifierId			=md.fkIdentifierId	and mp.fkFieldDescriptionId=md.fkFieldDescriptionId and md.ValueDate>=mp.ActiveFrom and md.ValueDate<=mp.ActiveTo
				join		BBG.AttributeUniverse		au			on	au.id						=mp.fkfielddescriptionid
				left join	BBG.MarketData				mdlclccy	on	mdlclccy.fkrequestcontrolid	=md.fkrequestcontrolid
																	and mdlclccy.valuedate			=md.valuedate
																	and	mdlclccy.fkIdentifierId		=md.fkIdentifierId
																	and mdlclccy.fkFieldDescriptionId=@quotedccyId	
				join	@CcyList					ccy			on	convert(varbinary,ccy.Ccy)		=convert(varbinary,mdlclccy.FieldValue)

				where	rgi.fkRequestGroupId	in (select fkRequestGroupId from @reqgrpid where fkSecurityProviderId=@SecProviderId)
				and		au.fieldmnemonic		<>'local_crncy'
				order by md.ValueDate,mp.[level] desc --force correct sequence

				insert @unqIdentifierAttribute(fkIdentifierId ,fkfieldDescriptionId) select distinct fkIdentifierId ,fkfieldDescriptionId from @MarketData

				--if there isn't a bfill ticker with the same ccy then
				insert #MarketDataChange (fkIdentifierId,fkFieldDescriptionId,prevdate ,prevvalue ,nextdate ,nextvalue ,ChangePercent)
					select 	 r.fkIdentifierId,r.fkfielddescriptionId
							,p.valuedate prevdate ,p.fieldvalue prevvalue
							,r.valuedate nextdate ,r.fieldvalue nextvalue
							,(convert(float,r.FieldValue)-convert(float,p.FieldValue))/p.fieldvalue ChangePercent
					from	@unqIdentifierAttribute	u
					join	@MarketData r	on	r.fkIdentifierId=u.fkIdentifierId and r.fkfielddescriptionId=u.fkfieldDescriptionId
					join	@MarketData p	on	p.id=r.id-1 
					where isnumeric(r.FieldValue)=1

				select	mp.OICode,
								md.valuedate,
								convert(varchar(32),md.valuedate,106)	displayvaluedate
								,PrimaryTicker
								,case when md.identifier<>mp.PrimaryTicker then md.identifier else '' end BackfillTicker
								,case when isnumeric(md.fieldvalue)=1 and md.fieldvalue is not null then
									convert(varchar(50),convert(decimal(38,10),md.fieldvalue))
								else
									md.fieldvalue
								end FieldValue,
								au.fieldmnemonic,
								isnull(mdc.ChangePercent,0.0) ChangePercent,
				--mdlclccy.*
				-- Change 2.1
								case when @isHedged=1 
									then 
										case when @HedgeCcy<>''
											then	@HedgeCcy
											else
												--get local
												(select	iso.ISOCcy 
												from ref.securityidentifier		sid 
												join ref.TickerLocalCurrencyMap m	on sid.id=m.fkIdentifierId 
												left join ref.ISOCurrency		iso on iso.id=m.fkLocalCurrencyMapId
												where m.fkSecurityProviderId=1 and sid.Identifier=md.Identifier
												)
										end
									else 
										case when isnull(mdlclccy.fieldvalue,'')<>'' 
												then	mdlclccy.fieldvalue
											else
												case when charindex('~',au.fieldmnemonic)>0
													then replace(au.fieldmnemonic,substring(au.fieldmnemonic,1,charindex('~',au.fieldmnemonic)),'')
													else ''
												end
										end
								end Currency,

								case when isnull(mdlclccy.fieldvalue,'')<>'' 
									then	
										case when @isHedged=1 and isnull(mdlclccy.fieldvalue,'')<>@HedgeCcy and @HedgeCcy<>''
											then 'N' 
											else 'Y' 
										end
									else
										'N'
								end		isLocal
				--select *
						from		BBG.RequestGroupItem		rgi
						join		BBG.MarketData				md			on	md.fkrequestcontrolid		=rgi.fkrequestcontrolid
						join		@TickerMap					mp			on	mp.fkIdentifierId			=md.fkIdentifierId
																			and mp.fkFieldDescriptionId		=md.fkFieldDescriptionId
						join		BBG.AttributeUniverse		au			on	au.id						=mp.fkfielddescriptionid
						left join	BBG.MarketData				mdlclccy	on	mdlclccy.fkrequestcontrolid	=md.fkrequestcontrolid
																			and mdlclccy.valuedate			=md.valuedate
																			and	mdlclccy.fkIdentifierId		=md.fkIdentifierId
																			and mdlclccy.fkFieldDescriptionId=@quotedccyId
						join	#MarketDataChange				mdc		on	mdc.fkIdentifierId			=md.fkIdentifierId 
																			and	mdc.fkFieldDescriptionId	=md.fkFieldDescriptionId 
																			and mdc.nextdate				=md.ValueDate
						join		@CcyList					ccy			on	convert(binary,ccy.Ccy)=convert(binary,mdlclccy.FieldValue)
						left join	ref.TickerLocalCurrencyMap	tlm			on	tlm.fkIdentifierId=md.fkIdentifierId and tlm.fkSecurityProviderId=@SecProviderId
						left join	ref.ISOCurrency				ISOcy		on	ISOcy.Id=tlm.fkLocalCurrencyMapId

						where	rgi.fkRequestGroupId	in (select fkRequestGroupId from @reqgrpid where fkSecurityProviderId=@SecProviderId)
						and		au.fieldmnemonic		not in ('quoted_crncy')
						and		mp.fkSourceProviderId	=@SecProviderId
						and		md.ValueDate			between mp.ActiveFrom and mp.ActiveTo
						and		mdlclccy.id is not null
						and		case when isnull(@ccy,'')<>'' then
										case	when isnull(mdlclccy.fieldvalue,'')<>'' 
													then	mdlclccy.fieldvalue
												else ''
										end 
									else mdlclccy.fieldvalue
								end 
								= case when isnull(@ccy,'')<>'' then @ccy else isnull(mdlclccy.fieldvalue,'') end
						order by md.ValueDate
			end
--goto okexit
	create index idx001 on #MarketDataChange(fkIdentifierId,fkFieldDescriptionId,nextdate)

--select '4',* from @MarketData
--select '4',* from #MarketDataChange

okexit:
end

