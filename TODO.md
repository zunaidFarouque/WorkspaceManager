A mode can never be mixed. it can only be active or none (inactive).

- on tab 2, 
    - we need to be able to make active an environment: change the calculation in tab 3 + Write in our memory json. dont apply changes to hardware complience. the change is only the calculation for tab 3, and the change should happen instantly. so if I go to tab 3, I should get new color applied based on the selection.
    - we need to be able to apply ideal target state: auto apply necessary changes in the tab 3.

- on tab 3,
    - we will be able to on/off hardware complience manually
    - if ideal applied from tab 2, the changes (on/off delta) is already placed in the tab 3. user can override (space button)/remove some change with backspace button

so workflow can be:
"I just need pure live performance":
1. open dashboard
2. go to tab 2 and make live performace mode active+apply
4. enter to commit

or
"I need pure live performance with wifi":
1. open dashboard
2. go to tab 2 and make live performace mode active+apply
3. go to tab 3 and remove change on wifi using backspace (or make it on by toggling on using space if it is currntly off)
4. enter to commit

we give flexibility to people.