# PanelID

Reports your laptop model and screen details so we can confirm the correct
replacement screen. Saves a small text file to your Desktop.

It only reads information. Nothing on your computer is changed.

---

## Step 1 — Download

**Right-click** this link and choose **Save link as…**

https://raw.githubusercontent.com/screenologist/panel-id/main/PanelID.ps1

Save it to your **Desktop**.

> A normal left-click opens the file as text in your browser. Use right-click.

---

## Step 2 — Open PowerShell

1. Press the **Windows key**
2. Type `powershell`
3. Click **Windows PowerShell** in the results

A terminal window opens. It may be dark blue or black depending on your
Windows version — either is correct.

---

## Step 3 — Go to your Desktop

Type this and press **Enter**:

```
cd ([Environment]::GetFolderPath('Desktop'))
```

---

## Step 4 — Run it

Type this and press **Enter**:

```
powershell -ExecutionPolicy Bypass -File .\PanelID.ps1
```

---

## Step 5 — Send us the INFO

It takes a few seconds. The results appear on screen and a text file opens
in Notepad. The file is on your Desktop, named like:

```
PanelID_2026-09-29_1015.txt
```

---

## What it reports

**Laptop** — make, model, system model, SKU, serial number
**Screen** — PnP ID, part number (if the screen stores one), maximum refresh rate
**Touch** — whether the laptop has a touchscreen, and the controller ID

---

## Questions

**Is this safe?**
Yes. It only reads information and writes one text file. Nothing is installed
or changed, and no administrator rights are needed.

**"Running scripts is disabled on this system"**
Retype the Step 4 command including `-ExecutionPolicy Bypass`.

**"Cannot find path ... Desktop because it does not exist"**
Use the Step 3 command exactly as written — it handles OneDrive Desktop
folders.

**I can't find the downloaded file.**
Redo Step 1 using **right-click → Save link as…**, not a normal click.

**The window closed too fast.**
The report is saved on your Desktop. Open it from there.

**It says "not stored in screen" for the part number.**
That's normal. Many laptop screens don't store a part number. The PnP ID is
enough for us to identify it.

---

Licensed under the MIT License.
