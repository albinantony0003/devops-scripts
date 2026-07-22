from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from webdriver_manager.chrome import ChromeDriverManager
from time import sleep

options = Options()
options.add_experimental_option("detach", True)

driver = webdriver.Chrome(service=Service(ChromeDriverManager().install()), options=options)

driver.get("https://christhurajchurchmanjappara.com/")

driver.maximize_window()

links = driver.find_elements("xpath", "//a[@href]")
for link in links:
    print(link.get_attribute("href"))

# for link in links:
#    if "Gallery" in link.get_attribute("innerHTML"):
#       link.click()
#       break

# sleep(3)

# gallery_album = driver.find_element("xpath", "//a[@data-title='കാലത്തിന്റെ കൈയൊപ്പ്']")
# gallery_album.click()
