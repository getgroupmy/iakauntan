import { assertEquals } from "jsr:@std/assert@1";
import { normalise } from "./provider.ts";

/**
 * Reading ssmsearch.com's answer.
 *
 * The rest of this function is network and database, and neither
 * belongs in a unit test. `normalise` is the part that is pure and the
 * part that decides what a person is shown to pick from — which, when
 * they pick it, becomes a registration number on an e-Invoice. Getting
 * it wrong is silent: a row read badly shows a plausible company with
 * somebody else's number.
 *
 * Their field names are read in several spellings on purpose, because
 * this is not a documented API and the shape is what their own
 * frontend happens to send today.
 */

Deno.test("reads a result the way their site sends it", () => {
  const out = normalise({
    data: [{
      id: 4242,
      name: "TM Technology Services Sdn Bhd",
      slug: "tm-technology-services",
      regNo: "201901030189",
      oldRegNo: "571389-H",
      typeId: 1,
    }],
    total: 1,
  }, 1, 20);

  assertEquals(out.items.length, 1);
  assertEquals(out.items[0].name, "TM Technology Services Sdn Bhd");
  assertEquals(out.items[0].reg_no, "201901030189");
  assertEquals(out.items[0].reg_no_old, "571389-H");
  assertEquals(out.items[0].entity_type_id, 1);
  // Filled from the id when they send no title, so the picker can say
  // "Company" rather than "1".
  assertEquals(out.items[0].entity_type, "Company");
  assertEquals(out.total, 1);
});

Deno.test("and under the other names they use for the same fields", () => {
  const out = normalise({
    items: [{
      companyId: "7",
      companyName: "Kedai Runcit Sejahtera",
      registrationNo: "202301001234",
      entityTypeId: 2,
      typeName: "Business",
    }],
  }, 1, 20);

  assertEquals(out.items[0].ssm_id, 7);
  assertEquals(out.items[0].name, "Kedai Runcit Sejahtera");
  assertEquals(out.items[0].reg_no, "202301001234");
  assertEquals(out.items[0].entity_type, "Business");
});

Deno.test("drops a row with no name rather than offering a blank one", () => {
  // A blank line in a picker is a thing somebody can select, and what
  // they would be selecting is a registration number with no company
  // attached to it.
  const out = normalise({
    data: [
      { id: 1, regNo: "201901030189" },
      { id: 2, name: "   ", regNo: "202301001234" },
      { id: 3, name: "Real Sdn Bhd" },
    ],
  }, 1, 20);

  assertEquals(out.items.length, 1);
  assertEquals(out.items[0].name, "Real Sdn Bhd");
});

Deno.test("survives an answer with nothing in it", () => {
  // Their endpoint answering `{}` must be "no matches", not a crash on
  // somebody's screen.
  const out = normalise({}, 1, 20);
  assertEquals(out.items, []);
  assertEquals(out.total, 0);
  assertEquals(out.page, 1);
  assertEquals(out.per_page, 20);
});

Deno.test("counts what it found when they send no total", () => {
  const out = normalise({
    data: [{ name: "One Sdn Bhd" }, { name: "Two Sdn Bhd" }],
  }, 2, 10);
  assertEquals(out.total, 2);
  assertEquals(out.page, 2);
});

Deno.test("takes a number as a name rather than losing the row", () => {
  // A business registered under digits alone is unusual and real, and
  // a reader that insisted on a string would drop it.
  const out = normalise({ data: [{ name: 12345, regNo: "202301001234" }] }, 1, 20);
  assertEquals(out.items[0].name, "12345");
});
