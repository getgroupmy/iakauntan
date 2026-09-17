# Running your own reader

MinerU, PaddleOCR, OCRmyPDF, docTR, or anything else that reads a page.
None of them can be embedded in this product — they are Python with
model weights, and the function that calls readers is Deno — so the way
in is an endpoint you run and a row in the catalog.

There is one protocol for all of them, not one per project. They differ
in how they read a page, not in what this system needs back.

## What is already covered without any of this

**Tesseract** is the free on-device reader. `text_reader_web.dart` runs
tesseract.js in the browser and ML Kit does the same job on a phone; the
file never leaves the machine and there is nothing to deploy.

**Scanned PDFs, on web.** The browser pulls text out of a PDF with the
bundled pdf.js and, when the text is thin enough to mean the page is a
photograph in a wrapper, renders it and reads it. That is most of what
OCRmyPDF would be for. It is worth deploying anyway for volume, and for
the phone — ML Kit takes an image and cannot open a PDF at all.

**What a self-hosted reader is actually for**: PaddleOCR for Chinese
text and for receipt tables, where a general reader loses columns;
MinerU for PDFs with real table structure.

## The contract

`POST` to your endpoint, `multipart/form-data`:

| part     | what                                                        |
|----------|-------------------------------------------------------------|
| `file`   | the document — an image or a PDF, with its content type      |
| `model`  | the catalog row's `model`, when one is set. Absent otherwise |
| `schema` | always `iakauntan.extraction.v1`                             |

`Authorization: Bearer <key>` when the catalog row has `takes_key`. A
service on a private network may need none; one reachable from the
internet certainly does.

Answer `200` with JSON — either the extraction itself, or `{"extraction":
{…}}`:

```json
{
  "supplier_name": "Kedai Runcit Sejahtera Sdn Bhd",
  "supplier_tax_id": "W10-1808-31000123",
  "supplier_registration_no": "201901030189",
  "supplier_email": null,
  "supplier_phone": "03-7890 1234",
  "supplier_address": "12 Jalan Ampang, 50450 Kuala Lumpur",
  "document_no": "INV-88213",
  "document_date": "2026-03-14",
  "currency": "MYR",
  "subtotal": 120.00,
  "tax_amount": 7.20,
  "total_amount": 127.20,
  "lines": [
    {"description": "Beras 10kg", "quantity": 2, "unit_price": 60.00,
     "amount": 120.00}
  ],
  "note": null
}
```

Every field is read and every one may be null. **Null and absent mean
the same thing here** — the function fills the shape rather than
trusting it — but null is the honest answer: "this receipt has no tax
number" and "I did not look" are different, and only the first is
useful.

Numbers may be numbers or strings. `"RM 1,234.50"` is read as
`1234.50`, the same forgiveness the CSV importers give, because a reader
that hands that back has read the page correctly.

`document_date` as `YYYY-MM-DD`.

Anything other than `200` is a failure, and the first 300 characters of
the body are shown to whoever pressed scan — so a readable message there
is worth writing. **A failure refunds the charge**; a success does not,
so a service that answers `200` with an empty extraction has taken
somebody's money for nothing.

The call times out at **120 seconds**. A cold container is slow and slow
is not broken, but it cannot be unbounded: the charge is taken before
the request and a call that never returns is a charge never refunded.

## Standing one up

PaddleOCR, roughly:

```yaml
services:
  reader:
    image: paddlepaddle/paddle:latest
    command: python /srv/serve.py
    volumes: ["./serve.py:/srv/serve.py:ro"]
    ports: ["8080:8080"]
```

`serve.py` is yours to write: accept the multipart above, run whichever
pipeline, and map its output into the JSON. That mapping is the whole
integration, and it is deliberately on your side of the line — it is
where a project's own idea of a "table cell" becomes this product's idea
of a line, and that is a judgement no protocol can make.

## Switching it on

1. Deploy the service and note its address. **HTTPS**, and reachable
   from Supabase's edge network — a `localhost` address will not do.
2. Platform console → OCR readers → MinerU, PaddleOCR or OCRmyPDF →
   set the endpoint.
3. If it needs a key, set the secret `OCR_KEY_<CODE>` in the Supabase
   dashboard, where `<CODE>` is the catalog code in capitals:
   `OCR_KEY_PADDLEOCR`. Never in this repository and never in the
   database.
4. Only then switch the row active. It ships inactive with no endpoint
   on purpose: a reader nobody has deployed is a door with nothing
   behind it, and the console would otherwise offer it.
5. A company chooses it in its own settings, like any other reader.

## What nobody has tested

The wire format above is asserted against a stub, not against a running
MinerU. The first person to deploy one is the first person to find out
whether their mapping is right, and the honest place to find out is a
scan of a receipt whose numbers you already know.
