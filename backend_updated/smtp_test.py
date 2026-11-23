import smtplib, ssl, getpass

user = input("Gmail: ").strip()
pw = getpass.getpass("App Password: ").replace(" ", "")

for port, mode in [(465, "ssl"), (587, "tls")]:
    try:
        ctx = ssl.create_default_context()
        if mode == "ssl":
            s = smtplib.SMTP_SSL("smtp.gmail.com", port, timeout=20, context=ctx)
        else:
            s = smtplib.SMTP("smtp.gmail.com", port, timeout=20)
            s.starttls(context=ctx)
        s.login(user, pw)
        print(port, "OK")
        s.quit()
    except Exception as e:
        print(port, "FAILED:", type(e).__name__, e)