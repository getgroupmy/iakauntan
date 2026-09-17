// smoke.ts — exercises ALL 13 SSM Search API endpoints against the free development host,
// using the sample values the documentation lists for the development key.
//
//   SSMSEARCH_API_KEY=... SSMSEARCH_API_SECRET=... deno run --allow-net --allow-env smoke.ts
//   (add SSMSEARCH_API_BASE_URL=https://apigw.ssmsearch.com/gateway/CIDP/V1.1/ ONLY if you want to spend credit)
//
// Prints one line per endpoint: OK / error kind, HTTP status, duration, and a short payload summary.
// Exit code 1 if any call failed for a reason other than "upstream" (which usually means the
// sample id is masked and needs a real one).

import { SsmApiError, SsmSearchClient, normalizeSearchResults } from "../supabase/functions/_shared/ssm-search-client.ts";

const client = SsmSearchClient.fromEnv(Deno.env, {
  clientRefPrefix: "smoke",
  onRequest: (i) => console.log(`   ↳ ${i.path} status=${i.status} ok=${i.ok} ${i.durationMs}ms ref=${i.clientRefNo}`),
});
console.log(`Base URL: ${client.baseUrl}\n`);

type Step = { name: string; run: () => Promise<unknown>; summarise?: (v: any) => string };
const steps: Step[] = [
  { name: "1  searchEntity (name)", run: () => client.searchEntity({ name: "BOSS", page: "1", entityType: "company" }), summarise: (v) => `${normalizeSearchResults(v).length} hits, page ${v.searchEntity?.currentPage} → next ${v.searchEntity?.nextPage}` },
  { name: "1b searchEntity (regNo)", run: () => client.searchEntity({ regNo: "19931215XXXX" }), summarise: (v) => `${normalizeSearchResults(v).length} hits` },
  { name: "1c searchAll (3 pages max)", run: () => client.searchAll({ name: "MAJU" }, { maxPages: 3 }), summarise: (v) => `${v.hits.length} hits over ${v.pagesFetched} page(s), exhausted=${v.exhausted}` },
  { name: "2  businessProfile", run: () => client.businessProfile({ regNo: "SP0503XXX-L" }), summarise: (v) => `${v.robBusinessInfo?.registrationName ?? "?"} status=${v.robBusinessInfo?.status ?? "?"}` },
  { name: "3  companyProfile", run: () => client.companyProfile({ regNo: "19931215XXXX" }), summarise: (v) => `${v.rocCompanyInfo?.companyName ?? "?"} status=${v.rocCompanyInfo?.companyStatus ?? "?"}` },
  { name: "4  directorsOfficers", run: () => client.directorsOfficers({ regNo: "200701042XXX" }), summarise: (v) => `${v.rocCompanyOfficerListInfo?.rocCompanyOfficerInfos?.rocCompanyOfficerInfos?.length ?? 0} officers` },
  { name: "5  shareCapital", run: () => client.shareCapital({ regNo: "200701042XXX" }), summarise: (v) => `totalIssued=${v.shareCapitalSummary?.totalIssued ?? "?"}` },
  { name: "6  shareholders", run: () => client.shareholders({ regNo: "200701042XXX" }), summarise: (v) => `${v.currShareholderList?.shareholders?.shareholders?.length ?? 0} current shareholders` },
  { name: "7  registeredAddressChanges", run: () => client.registeredAddressChanges({ regNo: "200701042XXX" }), summarise: (v) => `${v.rocRegAddressInfo?.address1 ?? "?"}` },
  { name: "8  companySecretary", run: () => client.companySecretary({ regNo: "200701042XXX" }), summarise: (v) => `${v.cosecs?.cosecs?.length ?? 0} cosec(s)` },
  { name: "9  companyCharges", run: () => client.companyCharges({ regNo: "200701042XXX" }), summarise: (v) => `${v.SSMRegistrationChargesInfos?.SSMRegistrationChargesInfos?.length ?? 0} charge(s)` },
  { name: "10 auditFirmProfile", run: () => client.auditFirmProfile({ adtFirmNo: "AF03XX" }), summarise: (v) => `${v.adtFirmProf?.adtFirmName ?? "?"}` },
  { name: "11 llpCurrentProfile", run: () => client.llpCurrentProfile({ entityNoOldFormat: "LLP00XXXXX-LGN" }), summarise: (v) => `${v.llpCurrentProfile?.llpBasicProfile?.entityName ?? "?"}` },
  { name: "12 imageView", run: () => client.imageView({ regNo: "200701022XXX" }), summarise: (v) => `${v.documentInfos?.documentInfos?.length ?? 0} document(s)` },
  { name: "13 image", run: () => client.image({ regNo: "200701022XXX", verId: "2026737" }), summarise: (v) => `docContent ${String(v.docContent ?? "").length} chars` },
  { name: "x  profileFor(company)", run: () => client.profileFor("company", { newRegNo: "19931215XXXX" }), summarise: () => "dispatched to companyProfile" },
];

let hardFailures = 0;
for (const s of steps) {
  const t0 = Date.now();
  try {
    const v = await s.run();
    console.log(`✔ ${s.name.padEnd(30)} ${Date.now() - t0}ms  ${s.summarise ? s.summarise(v) : ""}`);
  } catch (e) {
    if (e instanceof SsmApiError) {
      console.log(`✘ ${s.name.padEnd(30)} ${e.kind} http=${e.status} code=${e.code ?? "-"} — ${e.message}`);
      if (e.kind !== "upstream") hardFailures++;
      if (e.kind === "auth") { console.log("\nStopping: credentials rejected. Check SSMSEARCH_API_KEY / SSMSEARCH_API_SECRET."); break; }
    } else {
      console.log(`✘ ${s.name.padEnd(30)} unexpected: ${(e as Error).message}`);
      hardFailures++;
    }
  }
}
console.log(`\n${hardFailures === 0 ? "All endpoints reachable." : `${hardFailures} hard failure(s).`}`);
Deno.exit(hardFailures === 0 ? 0 : 1);
