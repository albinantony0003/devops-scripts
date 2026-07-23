from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from webdriver_manager.chrome import ChromeDriverManager
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from time import sleep
from tkinter import *
from tkinter import messagebox 

options = Options()
options.add_experimental_option("detach", True)

driver = webdriver.Chrome(service=Service(ChromeDriverManager().install()), options=options)

driver.get("https://kapitel-zwei.de/")

driver.maximize_window()

# Accept only essential cookies
try:
    essential_btn = WebDriverWait(driver, 10).until(
        EC.element_to_be_clickable((By.XPATH, "//button[contains(@class, 'brlbs-btn-accept-only-essential')]"))
    )
    essential_btn.click()
    sleep(2)  # wait for overlay animation to complete
except Exception as e:
    print("Could not click cookie button:", e)


links = driver.find_elements("xpath", "//a[@href]")
for link in links:
    if "https://kapitel-zwei.de/en/" in (link.get_attribute("href") or ""):
        if link.is_displayed():
            try:
                link.click()
            except Exception as click_err:
                messagebox.showerror("showerror", "Standard click was intercepted. Using JS fallback click.")
                driver.execute_script("arguments[0].click();", link)
                break
            else:
                messagebox.showinfo("showinfo", "Successfully clicked the visible English flag.")
                break

# root = Tk() 
# root.geometry("300x200") 

# w = Label(root, text ='GeeksForGeeks', font = "50") 
# w.pack()

# messagebox.showinfo("showinfo", "Information") 

# for link in links:
#    if "Gallery" in link.get_attribute("innerHTML"):
#       link.click()
#       break

# sleep(3)

# gallery_album = driver.find_element("xpath", "//a[@data-title='കാലത്തിന്റെ കൈയൊപ്പ്']")
# gallery_album.click()
