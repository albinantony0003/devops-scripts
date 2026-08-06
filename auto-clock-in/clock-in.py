from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from webdriver_manager.chrome import ChromeDriverManager

from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

from tkinter import messagebox
import pickle
import os

# --- Cookie persistence config ---
COOKIE_FILE = r"D:\Workplace\Chrome\keka_cookies.pkl"
SITE_URL    = "https://activelobby.keka.com/#/me/attendance/logs"

# --- Chrome options ---
options = webdriver.ChromeOptions()

# Keep the browser open after the script finishes
options.add_experimental_option("detach", True)

# Reuse the persistent Chrome profile so cookies/session data are saved automatically
options.add_argument(r"--user-data-dir=D:\Workplace\Chrome")
options.add_argument(r"--profile-directory=Default")  # Use the Default profile

# Suppress automation detection flags that can trigger forced logouts
options.add_experimental_option("excludeSwitches", ["enable-automation"])
options.add_experimental_option("useAutomationExtension", False)
options.add_argument("--disable-blink-features=AutomationControlled")

# Prevent Chrome from clearing session cookies on close
options.add_argument("--disable-session-crashed-bubble")
options.add_argument("--no-first-run")
options.add_argument("--no-default-browser-check")


# Start the webdriver (Selenium 4+ automatically downloads and manages the driver)
driver = webdriver.Chrome(service=Service(ChromeDriverManager().install()), options=options)

# Spoof navigator.webdriver to further reduce automation detection
driver.execute_cdp_cmd("Page.addScriptToEvaluateOnNewDocument", {
    "source": "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
})

driver.get(SITE_URL)
driver.maximize_window()

import time

# --- Inject saved cookies (if available) to restore the previous session ---
if os.path.exists(COOKIE_FILE):
    with open(COOKIE_FILE, "rb") as f:
        cookies = pickle.load(f)
    for cookie in cookies:
        # Remove keys that can cause issues when adding cookies
        cookie.pop("sameSite", None)
        try:
            driver.add_cookie(cookie)
        except Exception:
            pass  # Skip any cookies that are invalid for this domain
    # Reload the page so the injected cookies take effect
    driver.get(SITE_URL)
    time.sleep(2)

# --- Save current cookies for future runs ---
pickle.dump(driver.get_cookies(), open(COOKIE_FILE, "wb"))

# Wait up to 20 seconds for the "Web Clock-In" link to be visible and clickable
try:
    # Use a more specific XPath targeting the anchor containing the globe icon and the text
    web_clock_in_link = WebDriverWait(driver, 20).until(
        EC.element_to_be_clickable((By.XPATH, "//a[contains(@class, 'text-link') and .//span[contains(@class, 'ki ki-globe')] and contains(., 'Web Clock-In')]"))
    )
    
    # Try to click (up to 3 retries in case the event listener wasn't ready)
    clocked_in = False
    for attempt in range(3):
        try:
            web_clock_in_link.click()
        except Exception:
            driver.execute_script("arguments[0].click();", web_clock_in_link)
            
        print(f"Clicked Web Clock-In (Attempt {attempt + 1}). Verifying status change...")
        
        # Verify if clock-in succeeded by checking if the "Web Clock-out" button is now visible
        try:
            WebDriverWait(driver, 5).until(
                EC.presence_of_element_located((By.XPATH, "//button[contains(text(), 'Web Clock-out')]"))
            )
            messagebox.showinfo("showinfo", "Successfully Confirmed Clock-In!")
            clocked_in = True
            break
        except Exception:
            #messagebox.showerror("showerror", "Status did not change yet. Retrying...")
            time.sleep(1.5)
            
    if not clocked_in:
        messagebox.showerror("showerror", "Failed to clock in: Web Clock-out button did not appear after 3 attempts.")

except Exception as e:
    messagebox.showerror("showerror", "Could not find or click the Web Clock-In:", e)
