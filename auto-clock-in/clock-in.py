from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from webdriver_manager.chrome import ChromeDriverManager

from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

from tkinter import messagebox 

#initialize the options
options=webdriver.ChromeOptions()
options.add_experimental_option("detach", True)

#set Data Dir
options.add_argument(r"--user-data-dir=D:\Workplace\Chrome\Profile 1")


# Start the webdriver (Selenium 4+ automatically downloads and manages the driver)
driver = webdriver.Chrome(service=Service(ChromeDriverManager().install()), options=options)

driver.get("https://activelobby.keka.com/#/me/attendance/logs")
driver.maximize_window()

import time

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
            messagebox.showinfo("showinfo", "Successfully clocked in! Web Clock-out button is now visible.")
            clocked_in = True
            break
        except Exception:
            messagebox.showerror("showerror", "Status did not change yet. Retrying...")
            time.sleep(1.5)
            
    if not clocked_in:
        messagebox.showerror("showerror", "Failed to clock in: Web Clock-out button did not appear after 3 attempts.")

except Exception as e:
    messagebox.showerror("showerror", "Could not find or click the Web Clock-In:", e)
