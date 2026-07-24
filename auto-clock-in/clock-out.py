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


# Wait and click the "Web Clock-out" button if present
try:
    clock_out_button = WebDriverWait(driver, 10).until(
        EC.element_to_be_clickable((By.XPATH, "//button[contains(text(), 'Web Clock-out')]"))
    )
    clock_out_button.click()
    # messagebox.showinfo("showinfo", "Successfully clicked on Web Clock-out button.")

    # Wait for and click the final "Clock-out" confirmation button
    confirm_clock_out = WebDriverWait(driver, 5).until(
        EC.element_to_be_clickable((By.XPATH, "//button[text()='Clock-out']"))
    )
    confirm_clock_out.click()
    messagebox.showinfo("showinfo", "Successfully confirmed Clock-out.")
except Exception as e:
    messagebox.showerror("showerror", "Web Clock-out button was not found or is not clickable (possibly already clocked out):", e)
